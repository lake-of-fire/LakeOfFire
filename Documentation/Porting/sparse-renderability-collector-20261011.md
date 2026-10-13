# Sparse EPUB renderability: actual collector coverage

## 2026-10-11 06:45 UTC

Composes Lake #74 original head `6ebe5ddd938a999c20c207a4043e3577a46dab75` with current #50 `7ba92a8cc3cdd9bc481931fb214856fc751394fe`. All five original changed source/test blobs are retained, including #73's chapter-navigation ownership and #74's geometry-only sparse-anchor behavior. The later #50 import-storage collision/symlink fix and its tests remain intact. No stale dependency pin or generated project is selected.

Six new node:test cases evaluate the actual collectVisibleSegmentNodesFromRange declaration and its actual geometry/range helpers from ebook-viewer.js, with real imported viewport sampling and anchor helpers. Browser layout inputs are deterministic fixtures; semantic sidecar access throws if the readiness path touches it. Source boundaries fail explicitly if the viewer is reorganized. The collector logic is not copied or replaced by a test-only reducer.

With all nine viewport samples missing and a broad range claiming intersection, zero-size, offscreen and non-finite anchors must yield no visible segments and classifier outcome empty. A positive unidentified in-bounds sparse anchor must yield ready without semantic lookup. A range-rejected anchor remains rejected. Semantic collection does not acquire the unidentified fallback. Assertions also retain the nine-sample / one-anchor / one-measurement budget for the negative fallback cases.

These tests are authored but UNRUN. No builds, native apps, JavaScript tests, deployment or production changes were run. This is deterministic collector/classifier coverage, not browser layout or WebKit qualification. Keep draft for executing the existing JavaScript suite and real EPUB regression checks against the final dependency graph. Older helper-only tests and historical passes do not qualify this head.


## 2026-10-11 07:04 UTC newer audit adaptation

The owned #74/#73 changes are now adapted to #138 input `dc152a32197f9626013a0d13d667531c19d00b84`. Nine viewer hunks matched uniquely; two identical identity-admission hunks matched the two intended collector/measurement sites, and the import was inserted beside the existing writing-direction import without replacing main's makeDirectSectionURLResolver with the older stack's native-loader selection. All other current viewer content is retained.

The complete production geometry/collector declaration region is byte-identical to the repaired #74 region, and the actual imported readiness/sampling modules are identical in both operands. All four original helper/test blobs and the six-case collector test are preserved. Native chapter-refresh operation sequence/renderer/view-generation checks are included. This does not compose #50's native serving/initial-restore loader or storage graph; those remain separate. No tests or builds were run, and no browser/native qualification is claimed. Historical source checkpoints above are retained.
