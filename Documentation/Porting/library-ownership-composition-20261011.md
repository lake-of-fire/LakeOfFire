# Library ownership composition

## 2026-10-11 06:48 UTC

Original #95 head `67a76c535b1086828aeac4a304163a075517ec9a` is composed onto current #74 `3216f9e13c3e7306ece6e842a48e0250c5268c6d`, which includes current #50 import safety and sparse-renderability work. All fourteen original #95 changed blobs are retained exactly. Each destination path was still identical to #95's main base (or absent in both), so no newer implementation was replaced. The Package.swift change adds only LakeOfFireLibrary and OPML to the existing test target; no dependency version or pin changes.

This retains captured-Realm Library command ownership, locked reorder slots, final-write editability checks, scoped observers, prepared OPML export behavior and the disabled-script consolidation correction. Existing original tests are preserved, including the later observer regression. No retired validation system or generated project was introduced.

No builds, tests, app execution or deployment were run. The composed graph remains draft and requires real target discovery, observer scheduling, interrupted commands, account replacement and OPML qualification. Source composition is not native execution evidence. #54's live annotation consumer remains a separate dependent layer to refresh against this successor.


### 2026-10-11 06:57 UTC task-boundary correction

While adapting these commands into newer #138, review found that deleteCategory/restoreCategory read the MainActor-managed category.id inside a RealmBackgroundActor task. Both now capture the scalar ID before scheduling. Added one real-command archive/restore regression after global Realm replacement; it remains UNRUN. The same repair is present in #138 `404b155aa70df379da8a251177d2c367f91bca9d`, along with the bounded Library/OPML/observer transfer preserving its newer immutable consolidation. Broader Lake graph composition remains separate.


### 2026-10-11 07:02 UTC newer-audit disposition

The owned #95 Library scope is now represented in #138 `b4856c9862f862cc95c3525c5baef958ef7fb600`: exact view/command/test/manifest blobs except LibraryDataManager retains main's category-ID Set optimization, and consolidation deliberately preserves the newer immutable-admission implementation with the matching disabled-script eligibility correction. Its current duplicate-order/no-op journal regression is also retained. The new main-managed category archive/restore regression and scalar-capture fix are present in both branches. Historical references above remain evidence of the earlier composition steps, not current root selections. Closing the older Library-only PR does not close #50/#74 runtime/storage work or claim native qualification. All tests/builds remain unrun in this continuation.
