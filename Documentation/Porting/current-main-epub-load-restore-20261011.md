# Current-main EPUB load/restore composition — 2026-10-11

Reviewed Lake #138 58aac8d83225fece29ed7285b40706dcff0cd85f against retained #50 642250f9dee22b0460871006e803ae57151f5c12. The production coordinator and four behavior suites are carried from that reviewed source.

## Focused composition
Only the current viewer's loadEBook/loadLastPosition implementations, navigation-intent runner, imports and Reader.close notification hook change. The rest of the current viewer, including newer UI and lookup refinements, is retained. Existing EbookLoadResources and frame-timeout-scheduler are exact blobs matching the reference.

The coordinator distinguishes an absent saved location from explicit zero, keeps CFI-plus-historical-zero priority, propagates invalid/read/navigation failures and verifies the landed target before enabling position saving or successful restore effects. Ownership captures reader/view/renderer/request across awaits; newer loads and direct restores supersede old receipts. It aborts owned fetch/waits, removes frame/timeout handles, preserves newer global state during old cleanup, and permits identical retries after failed landing. Navigation-intent cleanup cannot resurrect an already completed predecessor.

## Scope of native capability support
The current viewer retains its legacy source factory. Explicit bound-session requests fail before replacing a valid reader because that factory cannot preserve a bound capability. Importing the source helper for token validation does not activate owned package serving or change native dependency selections. Full native receipt/package session integration remains separate.

## Paired Core status
The earlier note identifying Core #545's old producer describes that intermediate head, not the whole current Core stack. Core #183 e71646312b548e694dd878ffc79410f063347f4f already carries the awaited Realm hop, cancellation/deletion checks and validating saved-position initializer on the retained stack. Do not create a duplicate producer port. It requires this Lake API or the retained #50 equivalent. Selecting/qualifying the compatible tuple is still deferred; pins are unchanged.

## Evidence
Four JavaScript suites contain 80 behavior cases by source count: load coordinator 55, restore coordination 10, finalization 2 and validation 13. They execute production coordinator functions with browser/Reader/native-message boundaries doubled; they are not full EPUB layout or SwiftUIWebView/Realm qualification. No source-text assertion test was added.

All tests are UNRUN for this composed head. No build, syntax runner, native host, project generation, CI dispatch or deployment was performed. Previous #41/#50 results remain historical evidence, not current passes.

## Remaining / next
Review the viewer's renderer-level cancellation/navigation contract (view.js) and external callback consumers against the retained reference before claiming full parity. Paired Core completion-proof/cache publication, owned serving admission and Common schema/recovery composition remain open. No unfinished media/transcript feature is part of the hotfix release scope.
