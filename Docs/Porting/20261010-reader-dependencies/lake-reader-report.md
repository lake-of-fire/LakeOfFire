# Lake reader slice — 2026-10-10

This is a bounded, incomplete semantic audit with one focused implementation. It does not claim the reader slice is fully reconciled. No builds, tests, benchmarks, generators, native apps, installs, CI, commits, staging, pushing or PR creation ran. Tests are **not run by request**.

## Frozen evidence and ownership

- Hotfix dependency pin: `036d4193078016db0becdf91b86dd34fb1d579e0` (2026-10-09, Keep EPUB display ownership through geometry refresh).
- Target/main and unchanged local HEAD: `8985bf92b9504d53e00025e4054b3aa97f876e45`.
- [Lake #50](https://github.com/lake-of-fire/LakeOfFire/pull/50): `0b91431f0fe04c45b24b08b427a5df66e87661b9`, base main.
- [Lake #74](https://github.com/lake-of-fire/LakeOfFire/pull/74): `ad19065bd567f09f64a7f321feb2087fd60701fa`, base `port/epub-serving-safety-integration-20260928` (the #50 integration line).
- Additional compared relevant heads: [#53](https://github.com/lake-of-fire/LakeOfFire/pull/53) `35e0a7e65ce63365a9923a92fac832ad087c549b`; [#54](https://github.com/lake-of-fire/LakeOfFire/pull/54) `28c6911ada2221bc9a390de65f31b79bfba84bd4`; [#95](https://github.com/lake-of-fire/LakeOfFire/pull/95) `21c42ff0138c0b5b934956cbcccd107e5c577cf6`.
- Owned `Sources/LakeOfFireReader`, excluding `Reader/Books` assigned to files/books owner; corresponding JS and direct reader tests. Other modules inspected read-only. No repository-local AGENTS.md found. Root instructions and reconcile-hotfix-upstream skill read; maintain-bigsync-realm read for Settings mutation finding.

## Implemented: theme-equal-state-mutation

`Reader.swift::applyReaderTheme` unconditionally set three dataset attributes and two color-scheme style properties on main and #50, including repeated scene activation. Hotfix compares all five values before setting them. Provenance: `861190527a7df6ddc079319f78d3999b3a8b02cb`, dated 2026-06-16, with surviving implementation at frozen hotfix endpoint.

Surgical port now compares each existing value. Initial theme, changed scheme/theme, newly mounted explicit EPUB document and current renderer document iteration remain intact. `appliedCount` now describes changed documents; no live consumer depended on unconditional count (viewer document-load call ignores the return). No navigation, resource packaging, renderer, or producer schema changes.

Unstaged deliverables:

- `Sources/LakeOfFireReader/Reader/Reader.swift`: only compare-before-write implementation inside `applyTheme`.
- `Tests/LakeOfFireTests/ReaderThemeMutationTests.swift`: two runtime JavaScriptCore tests execute the actual JavaScript supplied by `applyReaderTheme` through its evaluator. Proxy dataset setters and style setters count mutations. They cover initial two documents, identical scene activation, changed color scheme, newly loaded explicit document and duplicate renderer entries. No source-file loading or implementation-text assertions.

Test ownership: existing `Package.swift` LakeOfFireTests target includes `Tests/LakeOfFireTests` and LakeOfFireReader dependency, so new file belongs to existing target without manifest edit. Compile, discovery and execution remain unverified by request. `git diff --check` for changed files passed; static diff manually inspected.

## Concrete residual findings

1. **P1 document-mutation admission — partially/incorrectly ported.** Main and inspected #50/#53 handlers lack hotfix `ReaderDocumentMutationAdmission`. `ReaderMessageHandlersViewModifier` readability unavailable/parsed checks trust claimed page/window equality; metadata only compares payload URL to mutable state; image handler accepts any non-native claimed URL on RealmBackgroundActor and loads/persists image updates. RSS similarly lacks complete WebKit provenance/current document fencing. Hotfix provenance `cfb348e6` (2026-08-30) adds frame-main-document/current-document checks, main-frame requirements where appropriate, and post-await current checks. `ReaderViewModel.pageMetadataUpdated` on main loads `state.pageURL` after crossing to RealmBackgroundActor and has no captured expected document guard around resolution/writes; hotfix accepts expectedDocumentURL and uses captured target. Next boundary: adapt using upstream immutable WebView receipt/current-document ownership, then test stale same-URL reload, different-document replacement, frame spoofing, cancellation and delayed Realm resolution. Do not blindly transplant URL-only hotfix checks. No broad repair attempted.

2. **P1 independent Realm transaction ownership — unresolved compatibility.** `ReaderSettings.swift::DataSettingsForm` clear-history and clear-unsaved-feed branches use `realm.asyncWrite` at main/#50/#95; hotfix Oct 4 `a0d0e896` changes to `asyncWritePreservingOwnership`. Both already use RealmBackgroundActor, correct existing configuration and in-transaction tombstone+explicit metadata refresh. Parent verified fresh Realm main `ffb9b50248291b7f13d6df42a27d8f1383ca618e` has no `asyncWritePreservingOwnership` API; local original RealmSwiftGaps grep also found none. Adding this call would create an unsupported dependency requirement. Next boundary is dependency owner identifying upstream-compatible independent transaction semantics before modifying these two callers. No runtime regression source added for unavailable API; tests missing for competing transactions/cancelled authority at these actions.

3. **Sidecar producer authority/retention — partial main, substantial pending #50 coverage.** Main `ReaderExternalSegmentSidecar` exposes public authoritative default and schema10. Main persistence verifies SHA token and atomic disk writes but does not bound disk retention. #50 has source-bound one-shot completion proof in `ReaderEbookTextProcessor`, private completion state, deep admission, content-addressed leased bounded retention, unknown/corrupt-artifact cleanup, process-shared disk leases and retry token. These are pending ports; do not duplicate or replace with hotfix's simpler pruning. However #50 remains schema10 versus hotfix12; exact cross-package producer/sidecar table/consumer/cache-generation composition remains unresolved. Review ReaderCore producer and Viewer metadata/cache/restore membership end to end before schema migration. Existing retained sidecar tests inspect eviction/recreation, atomic regeneration, write failure/inline fallback and scheme response; test execution not run.

4. **Readability consumer resource owner — integration uncertainty, other-owner module.** Main and #50 `Sources/LakeOfFireContent/User Scripts/ReadabilityScript.swift` load Lake's copied JS. Copied SHA256 `78f91045bc63c211bbb98f566a97a02422e2a7caabbc67005e9ffae3c7990cc5`; fresh swift-readability target resource SHA256 `e618517ab338057a7e70d04dec6577a7ba79b31af95c7de1d583496285794a18`. Equality/provenance alone is insufficient to establish semantic mismatch. Parent informed to coordinate with content/library and editor owner. No edit outside slice.

## Preserved upstream and pending behaviors

- Main `NavigationTaskManager` document generation, commit/finish phase, pending same-document URL queue, replacement cancellation and current operation checks are stronger than a task-only transplant. `ReaderWebViewHandler` invalidation, preserved committed-document failure disposition, navigation-token retirement and cancellation checks around content loading remain intact. Full-host callback tests are still unrun; whole UI integration not claimed verified.
- #74 `visibleSegmentProbeAcceptsIdentity` allows geometry-only renderability probes without semantic sidecar while metadata probes still require stable identity; `boundedRenderabilityAnchorSegment` bounds anchor selection. `navButtonRefreshIsCurrent` rejects closed/wrong renderer, wrong operation sequence/view generation, and active navigation. Inspected helper source and geometry test semantics. Pending coverage; not duplicated.
- Hotfix Reader Content module copies translate to main LakeOfFireContentUI. #54's stream observation/update files and `.task(id: URL+compoundKey)` preserve cancellation and row identity; pending coverage. Main modular native/media providers and bridge remain; deletion on hotfix is not a reason to delete upstream architecture.
- Main EPUB source destroy is idempotent; live Viewer uses OwnedAsyncResource/OwnedPromiseSlot/OwnedScheduledTask and source destroy call paths. Existing `epub-source-lifecycle.test.mjs` checks exactly-once destroy and rejected asynchronous cleanup. Broad EPUB loader/renderer lifecycle final-state differences remain unresolved.
- Import/whitespace-only deltas in Feed Model Extensions, ReadabilityContentTransformations, ReaderEnvironmentViewModifier, ReaderHTTPErrorRecoveryPolicy, ReaderModeButton, ReaderToastBar, ReaderToastsView, ReaderViewModelActor and String+StrippingHTML do not require porting redundant imports or loss of main Sendable.
- Page-turn experiments and test-RPC clients remain explicitly excluded. The hotfix moved resource monolith is not transplanted into main's decomposed runtime.

## Deterministic coverage and recorded shuffled pass

The owned dated module inventory has **671 unique path rows**: 54 Swift, 102 JavaScript, 510 PDF asset rows, 5 other. [Exact ledger](lake-reader-coverage.tsv) records every path, translated main/hotfix live path, endpoint equality, disposition and remaining step. The root's `lake-exact-moves.json` proves 255 identical PDF asset old→new moves, accounting for **510 dated path rows**; retain main packaging. Twelve additional exact moves are recorded there; endpoint equality does not close caller integration.

Ledger counts: 11 correctly ported path families (limited to reason stated), 2 correctly ported pending #54 paths, 7 partially/incorrectly ported paths, 523 intentionally divergent/retired or unchanged relocated asset rows, **128 unresolved paths**. Large ReaderMode, Viewer, paginator, native mark-read, cache, projection/media and generation transport families are not exhaustively semantically closed. Report counts are path accounting, not progress percentages.

Deterministic pass inspected message decoders/handlers/current metadata persistence, theme callers/production script, sidecar capability + cache-store persistence, relevant #50/#74 source, navigation ownership, small import-only deltas and corresponding existing runtime contract source. Reproducible shuffle seed `20261010` used Python `random.Random(20261010).shuffle` on named remaining clusters. Order and results:

1. media bridge — main media/native source integration retained; broad provider composition unresolved.
2. message admission — concrete metadata/image/RSS and post-suspension gaps above remain.
3. diagnostic script — main render-ready generation/visibility and diagnostic tracked-segment probes retained; no hotfix diagnostic simplification port.
4. reader presentation — theme fix; main presentation-state signature dedup retained, independent from Swift scene-active theme path.
5. navigation lifecycle — stronger main phase/generation ownership preserved; no hotfix transplant.
6. resource lifecycle — destroy/cache ownership path inspected; broad mixed renderer rewrite unresolved.
7. sidecar persistence — #50 leased producer retention reviewed; schema and producer composition unresolved.
8. annotation module moves — ContentUI live owner and #54 async stream cancellation inspected read-only; rest delegated owner.

Tests are separately inventoried in [test coverage ledger](lake-reader-test-coverage.tsv): 81 dated candidate test paths, 5 existing runtime contract sources inspected, remaining semantic comparisons unresolved; new two-test theme source and #74 renderability helper test inspection recorded separately. Never restored removed validation/source-string assertion tests. Documentation inspected: hotfix and #50 `Documentation/epub-serving-integration-20260926.md` explicitly retain coordinated Core/Common adoption and native/two-client qualification as unfinished; no completion claim imported from that doc. Other dated reader docs/config/generated outputs are outside this module source ledger and remain parent/files-books ownership, not silently counted as reviewed.

## Exact next audit boundary

Finish the **128 unresolved source rows** in `lake-reader-coverage.tsv`, concentrating first on ReaderModeViewModel+ReaderMessageHandlers+ReaderViewModel document authority, ReaderExternalSegmentSidecar schema12 producer and Viewer cache/metadata consumer, then Viewer/paginator/fixed-layout/restore/progress callback publication. Audit eligible historical provenance, not all older architecture deltas. Compare actual #50/#74 integration line, with #50 importIdentity in BookGridCell owned by files-books preserved. Reconcile the remaining **76 dated candidate test sources** method-by-method against live owners and pending PRs. Any later source pin/main/PR head is a separate unaudited tail; this report freezes the SHAs above.
