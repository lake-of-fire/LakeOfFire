# Sparse EPUB renderability: actual collector coverage

## 2026-10-11 06:45 UTC

Composes Lake #74 original head `6ebe5ddd938a999c20c207a4043e3577a46dab75` with current #50 `7ba92a8cc3cdd9bc481931fb214856fc751394fe`. All five original changed source/test blobs are retained, including #73's chapter-navigation ownership and #74's geometry-only sparse-anchor behavior. The later #50 import-storage collision/symlink fix and its tests remain intact. No stale dependency pin or generated project is selected.

Six new node:test cases evaluate the actual collectVisibleSegmentNodesFromRange declaration and its actual geometry/range helpers from ebook-viewer.js, with real imported viewport sampling and anchor helpers. Browser layout inputs are deterministic fixtures; semantic sidecar access throws if the readiness path touches it. Source boundaries fail explicitly if the viewer is reorganized. The collector logic is not copied or replaced by a test-only reducer.

With all nine viewport samples missing and a broad range claiming intersection, zero-size, offscreen and non-finite anchors must yield no visible segments and classifier outcome empty. A positive unidentified in-bounds sparse anchor must yield ready without semantic lookup. A range-rejected anchor remains rejected. Semantic collection does not acquire the unidentified fallback. Assertions also retain the nine-sample / one-anchor / one-measurement budget for the negative fallback cases.

These tests are authored but UNRUN. No builds, native apps, JavaScript tests, deployment or production changes were run. This is deterministic collector/classifier coverage, not browser layout or WebKit qualification. Keep draft for executing the existing JavaScript suite and real EPUB regression checks against the final dependency graph. Older helper-only tests and historical passes do not qualify this head.
