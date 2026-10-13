# Retained regression coverage reconciliation — 2026-10-11

Compared retained Lake #50 47c3307ef93e91dd3295ab31704a5446705d43ed with #138 9b716c87ee266dfd9f2e1e13be414e2e7cd15733.

## Carried and adapted evidence

ReaderEBookNativeRestoreInitializationTests supplies six helper-plus-restore-bridge composition methods. The first now uses #138's actual no-op preparation shape and checks the captured binding directly; #50's synthetic task-local fixture and synthetic package result are not asserted as current production integration. Coverage includes saved zero, invalid fractions, read errors, genuine absence, cancelled nil, and replacement during lookup followed by a valid fresh receipt.

ReaderPackageResourceBudgetTests is not copied wholesale: its low-level boundaries overlap the already-composed ReaderPackageResourceLimitTests and package source tests. Added three complementary methods to the existing owning file: preset read limits versus catalog admission, exact aggregate capacity with empty entries and non-consuming rejection, and UTF-8 path rejection without budget consumption. Existing cases already cover negative limits, overflow, rejected chunks, directory count, actual-byte bounds, and both storage kinds. The original #50 file remains intact as historical evidence.

All nine additional methods are UNRUN; Swift UNCOMPILED. No production edits, native launches, generation, builds, tests, CI, pins or deployments in this chunk. Reader #384's explicit source registration must include the six-method initialization composition file; the resource-limit file was already registered.

## Remaining older evidence is not silently declared superseded

- ArticleReadingProgressEpochPortTests: coupled to unresolved read-authority schema composition; do not add model fields or pins to make a test compile.
- Serving-session, handler and serving composition suites: require the matching owned-serving implementation, Core hook and lifetime semantics, still open.
- WebKit restore suite: real-host qualification remains unperformed; do not run while native execution is held.
- Native loader/source JS suites: tied to owned package-session loader/section contract, still open.
- Portable runners: do not restore retired validation systems merely to match old paths.

#50 remains open. Next review concerns owned package lifetime, cached-resource admission and current main architecture.
