# Library command, observer and OPML upstream reconciliation

## 2026-10-11 06:56 UTC

Source: #95 `7b6c4e63ed2c5fad34237b36c663c17a0ab4ae5c`. Destination: newer #138 `9b8f58cb95c5badbd288493e2e57226eda616607`.

Port the missing captured-Realm view/command, scoped observer and prepared OPML source and regression fixtures. Destination view/test paths were unchanged from #95's base or absent. Preserve the newer immutable consolidation implementation and its disabled-script correction; do not copy #95's older consolidation algorithm. The original corrected consolidation tests are already present.

LibraryDataManager requires actual hunk composition: retain main's precomputed importedCategoryIDSet optimization while applying all nine #95 hunks. Two observer callbacks have identical context, so the second callback's larger hunk was applied first and the remaining callback was then uniquely matched. The resulting file differs from #95 only by the retained category-ID set optimization. Package.swift adds the missing OPML test dependency while preserving the existing LakeOfFireLibrary dependency and all dependency versions/pins.

Additional source-review repair: LibraryCategoriesViewModel.deleteCategory/restoreCategory formerly read category.id inside a RealmBackgroundActor task while accepting a MainActor-managed category. Capture the scalar ID on MainActor before creating either task. A new real-command regression passes a main-managed category through archive and restore after replacing the global Realm configuration, verifies the original store, and checks that the replacement remains untouched. No managed object needs to cross that task boundary for those commands.

Retained regression fixtures cover captured mutation APIs, locked reorder slots, final-write editability, prepared-file export/retry/cleanup, scoped observers and disabled-script convergence. They now live beside the newer audit's immutable-consolidation and Library field/domain tests. All are UNRUN; no native build, test command, app, package resolution or production change was performed. Source composition does not establish observer scheduling or actual ShareLink lifetime. Same-key model incarnation and broader post-await UI publication authority remain separate review/qualification boundaries.

This completes the bounded #95 Library source transfer into #138, not the wider #50/#74/#54 runtime/storage/annotation stack. Keep both drafts until their remaining dependencies and qualification are reconciled; do not close a PR based on this document alone.
