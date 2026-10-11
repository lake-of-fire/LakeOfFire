# Script editor owned-write continuation — 2026-10-11

## Exact source review

Parent Lake #155 `c01a0b0d2d04a3669fb519ffc0e2afbefb517456`.
Hotfix comparison Lake #150 `38857b1f954e403eff73561caf2769de06bdb9ea`.
Required RealmSwiftGaps #7 `d718c99064ae16d1d0fdd675224494d6ee8c8ff9`, rechecked before this change.

The newer main script editor already improves on hotfix with immutable script/domain incarnation owners and current-input intent admission. Preserve those implementations. Three final writers still use SDK asyncWrite directly:
1. LibraryScriptFieldCommand.write (all script fields).
2. LibraryScriptDomainOwner.write (add/remove selected allowed domains).
3. UserScriptAllowedDomainEdit.write (one domain's text).

Corresponding hotfix field/domain mutations use asyncWritePreservingOwnership. Adapt only that transaction boundary; do not transplant older hotfix model/UI architecture. Each reviewed closure is synchronous, resolves its target inside admission, contains no ThreadSafeReference resolution or nested transaction, and journals only actual admitted changes.

## Changes

Replace those three direct SDK boundaries with the existing owned-write API. Retain pre-admission and inside-transaction cancellation checks, owner/incarnation and live membership guards, per-field input order, synchronized soft-deletion and shared batch timestamps.
No schema, model, sync-policy or UI changes. No blanket replacement elsewhere.

Five authored regression methods cover durable post-submission cancellation for field updates, domain text, domain addition and domain deletion, plus pre-cancelled domain deletion. Existing pre-cancelled/suspended field/domain cases remain. The two suites now contain 15 field methods and 13 domain methods (28 total).

## Verification and remaining limits

All 28 methods are UNCOMPILED/UNRUN on this candidate. Existing RealmWriteCommitObservation supplies task-local cancellation after submission; no new global hook or timing race is introduced.
Source review only, no runtime reproduction/pass claim. No native build, generation, launch, test, CI dispatch, merge, deployment or Reader dependency pin advance.
Requires the composed RealmSwiftGaps boundary; package discovery is directory-based, while assembled app test-plan inclusion remains separately unverified.
Physical store/account generation and same-ID/same-createdAt replacement remain outside this patch. Native validation of these suites and the containing dependency tuple is still required before merge.
