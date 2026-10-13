# Disabled-script convergence in the newer Lake audit

## 2026-10-11 06:52 UTC

Operands: newer #138 `33a3d27baa893606931a8b6f2c1ea6ef52295124`; older Library ownership #95 `7b6c4e63ed2c5fad34237b36c663c17a0ab4ae5c` (policy correction first published at `67a76c535b1086828aeac4a304163a075517ec9a`).

The newer immutable/final-transaction consolidation implementation still excluded isArchived scripts in three places: retained primary references, resolved duplicate references and orphan admission. The actual refreshScripts caller includes every non-deleted script, and the Library UI treats archived scripts as Disabled with a re-enable control. This leaves the same remove/re-add convergence gap already repaired on #95.

Adapt the eligibility correction at those three current-owner sites only. Preserve the newer immutable admission keys, deterministic duplicate/tie order, unresolved CloudKit references, final transaction, stable-key re-resolution and mutation journaling. Category archive rules and execution filters are unchanged. Do not replace this implementation with #95's older consolidation algorithm.

The original consolidation regression file was unchanged in #138, so retain #95's complete corrected test blob: archived-orphan expectation includes disabled scripts, and the added existing-slot/no-op/re-enable regression remains. Add one newer-owner regression covering disabled duplicate admission alongside immutable ordering, deleted target exclusion, repeated no-op journal generations and re-enable stability. Existing immutable/unresolved ordering regressions remain intact.

All tests are authored but UNRUN. This is not a complete #95 composition: the real scoped-observer test and captured-Realm command/view/OPML ports still need reconciliation. Current #138 LibraryDataManager and #95 differ, and the broader file-inventory/runtime overlap remains open. No builds, tests, package pins, generated projects, retired validation systems or production changes. Keep draft.
