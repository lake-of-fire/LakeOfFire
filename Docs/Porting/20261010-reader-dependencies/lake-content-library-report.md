# Lake content/library audit slice — 2026-10-10

Scope: Sources/LakeOfFireContent excluding Files, Sources/LakeOfFireContentUI, Sources/LakeOfFireLibrary, and Sources/LakeOfFireMedia if present. No recursive AGENTS.md exists in LakeOfFire. Root instructions and reconcile-hotfix-upstream/maintain-bigsync-realm were read. Root HOTFIX-PORT ledger read critically, untouched. Files/import owners and shared report untouched.

## Exact frozen endpoints

Hotfix root-selected dependency: `036d4193078016db0becdf91b86dd34fb1d579e0`. Main target/worktree base: `8985bf92b9504d53e00025e4054b3aa97f876e45`. Original hotfix dirty checkout is WIP only and not read as implementation evidence. Nonshallow frozen repository. Relevant source provenance: `2f6e08e0bca0c4303b1b4dbc7ac16fd02e3e53b4` (2026-09-07) introduced source-known body guard, canonical merged entries and miss recheck; ordered Atom publication dates to module split `17b292c11389adcec8725e4716dc8cfa7855ee88`. Source comparison is final endpoints, not cherry-pick equivalence.

Pending heads checked by file scope and affected owners (all upstream PRs, including integration-branch bases):

- [#137](https://github.com/lake-of-fire/LakeOfFire/pull/137): `8b9d8381ce7561625452545b99260b29aaf81f37`, base `v3-hotfix`. Hotfix-only; does not close upstream gap.
- [#113](https://github.com/lake-of-fire/LakeOfFire/pull/113): `9ef23abaecf93eb24dfbe55cbf02e9598f4f935f`, base `v3-hotfix`. Hotfix-only; does not close upstream gap.
- [#95](https://github.com/lake-of-fire/LakeOfFire/pull/95): `21c42ff0138c0b5b934956cbcccd107e5c577cf6`, base `main`. Compared affected owned paths; existing pending ports not duplicated.
- [#74](https://github.com/lake-of-fire/LakeOfFire/pull/74): `ad19065bd567f09f64a7f321feb2087fd60701fa`, base `port/epub-serving-safety-integration-20260928`. Compared affected owned paths; existing pending ports not duplicated.
- [#61](https://github.com/lake-of-fire/LakeOfFire/pull/61): `0dc1e429fc8e2d2b7e7f2a176fe2f72fabc7ab9e`, base `port/epub-serving-safety-integration-20260928`. Compared affected owned paths; existing pending ports not duplicated.
- [#59](https://github.com/lake-of-fire/LakeOfFire/pull/59): `0dd0b07afac69c6d02512a7b02ff2acb27bf7bb0`, base `port/epub-serving-safety-integration-20260928`. Compared affected owned paths; existing pending ports not duplicated.
- [#54](https://github.com/lake-of-fire/LakeOfFire/pull/54): `28c6911ada2221bc9a390de65f31b79bfba84bd4`, base `main`. Compared affected owned paths; existing pending ports not duplicated.
- [#53](https://github.com/lake-of-fire/LakeOfFire/pull/53): `35e0a7e65ce63365a9923a92fac832ad087c549b`, base `main`. Compared affected owned paths; existing pending ports not duplicated.
- [#51](https://github.com/lake-of-fire/LakeOfFire/pull/51): `547b1e88a836c8c4b53c24c98294700e9066a745`, base `main`. Compared affected owned paths; existing pending ports not duplicated.
- [#50](https://github.com/lake-of-fire/LakeOfFire/pull/50): `0b91431f0fe04c45b24b08b427a5df66e87661b9`, base `main`. Compared affected owned paths; existing pending ports not duplicated.
- [#48](https://github.com/lake-of-fire/LakeOfFire/pull/48): `2f3a63733583e179bddc8025a7320141fc1ddade`, base `main`. Compared affected owned paths; existing pending ports not duplicated.
- [#41](https://github.com/lake-of-fire/LakeOfFire/pull/41): `af14b895d9d3e1a1fe8c3a00e52c158d6eae211e`, base `main`. Compared affected owned paths; existing pending ports not duplicated.

## Focused implementation, unstaged WIP

1. `ReaderContentLoader.load(url:)`: canonical history miss is rechecked inside the actor-bound write. Existing canonical or loader-alias capture is returned, no default upsert; live aliases preferred then tombstoned aliases by visit/compoundKey. Non-visit keeps tombstone/visit timestamp, visit revives existing row with explicit refresh. Upstream canonical URL aliases/cache revisions/invalidation retained.
2. `Feed.persist(atomItems:)`: complete ordered voice-audio list stored plus primary first URL. URL-array comparator observes secondary-only changes. Existing payload/mirror transport and navigation consumers retain full arrays.
3. `FeedEntryPayload.containsFullContent`: source feed option captured for RSS and Atom, carried explicitly to entry/mirrors. `applyFeedBody` ignores absent/empty bodies and summaries against full captures and promotes full authority once. `FeedEntry.configureBookmark` and history visit configuration share guard, preventing later visits from revoking capture before refresh. Unchanged entry bodies receive body-only mirror authority projection (no reader metadata replay); comparator excludes explicit mutation timestamp. Authority promotion on identical full body reaches mirrors and later identical refresh suppresses refresh/journal generation. No body-length inference and no schema fields added.
4. Canonical FeedView article projection **deferred after independent review**: deduplication can hide a currently selected occurrence or a different collection membership. No FeedView source edits remain. Requires scope-owned selection and collection presentation regression before porting.

No duplicated #95 captured-library command or #54 annotation-observation implementation. #137 is v3-hotfix-only, not upstream acceptance.

## Regression ownership / checks

Added `FeedContentPreservationTests.swift` (3 runtime methods: absent/summary full capture, equal full-body promotion/no-op, body plus ordered media payload). Added `ReaderHistoryMissPreservationTests.swift` (cached miss then committed capture, identity/body/title/full flag, no visit change; visit revives tombstone). Extended `AsahiFeedReadabilityPipelineTests.swift` with actual Atom parser→entry→bookmark/history ordered list and unchanged primary/changed secondary; captured bodies/flags survive refresh and subsequent source history visit; identical false→true full authority promotes mirror while preserving reader-owned media, repeat keeps entry/mirror mutation timestamps. Existing URLProtocol fixture and owning LakeOfFireTests package target reused. No source-string assertions.

`git diff --check` for assigned edited source/test paths passed. **Builds/tests/benchmarks/native apps: not run by request.** No runtime results, discovery, platform or cold-reopen claims. Package target source path includes new tests; generated app target/test-plan execution unproved.

## Deterministic path coverage and exact remaining work

57 differing review source paths plus 3 endpoint-equal dated paths = 60 assigned dated source paths excluding Content/Files. Each listed below. This is path accounting, **not complete semantic closure**. Source clusters reviewed deterministically: feed parser→payload→entry→mirror→history/Bookmark→FeedView/collection; all pending PR affected owned paths; library captured-Realm command and feed editor field/request owners; ReaderContent selection completion; resources/CSS wrappers and upstream image ownership. Other paths remain explicitly unresolved.

| Path | Status / evidence / remaining |
|---|---|
| `Sources/LakeOfFireContent/DefaultRealmConfiguration.swift` | Correctly ported in inspected schema branch: v72 transcript cache discard same code, wording only differs. Other schema integration requires app owner. |
| `Sources/LakeOfFireContent/Feeds/Feed Models.swift` | Partially ported → WIP focused fix: ordered Atom arrays/comparator and feed body authority. Remaining request admission, enrichment partition, durable mirror debt and membership observation unresolved. |
| `Sources/LakeOfFireContent/Library/LibraryConfiguration+Consolidation.swift` | Genuinely missing stronger hotfix immutable admission/unresolved relationship retention; main retains older owner here. #95 does not port consolidation policy. Implementation deferred. |
| `Sources/LakeOfFireContent/Library/LibraryDataManager.swift` | Partially ported: pending #95 captured Realm commands/observer and OPML prepared file. Hotfix consolidation moved into this file; immutable admission and atomic snippet import/storage ownership remain unresolved. |
| `Sources/LakeOfFireContent/Library/OPMLSendable.swift` | Intentionally divergent: upstream Swift 6 sendability shim retained; hotfix deleted it. OPML captured value transport reviewed in pending #95. |
| `Sources/LakeOfFireContent/Reader/PlainTextHTMLConverter.swift` | Intentionally divergent physical layout: hotfix moves normalization into ReaderContentTextIngestion; main retains converter. Both handle extension-only .md; conflicting MIME/type precedence not fully qualified. |
| `Sources/LakeOfFireContent/Reader/ReaderContent.swift` | Genuinely missing: persistent selection identity, cached/preloaded retirement and displaced completed-read rejection absent main and upstream PRs. Snippet title durable-before-publication missing. Not implemented. |
| `Sources/LakeOfFireContent/Reader/ReaderContentLoader.swift` | Partially ported → WIP canonical miss transaction recheck. Storage capture/replacement fencing and snippet command ownership remain unresolved. |
| `Sources/LakeOfFireContent/Reader/ReaderContentProtocol Extensions.swift` | Intentionally divergent DEBUG transcript-tracer helper; no upstream requirement established. |
| `Sources/LakeOfFireContent/Reader/ReaderContentProtocol.swift` | Partially ported → WIP preserves captured body/authority on history visits. Initial ebook restore belongs to pending #41/#50 (also #59/#61/#74); broader captured storage and history failure ownership remain unresolved. |
| `Sources/LakeOfFireContent/Reader/ReaderContentTextIngestion.swift` | Translated to main PlainTextHTMLConverter. Shared format detection reviewed; contradictory MIME/type precedence remains unresolved. |
| `Sources/LakeOfFireContent/Reader/TranscriptPageRegistry.swift` | Intentionally divergent retained upstream transcript architecture; hotfix absence not an instruction to remove validated transcript content. Full mixed-provider policy unresolved. |
| `Sources/LakeOfFireContent/Reader/WebViewNavigator+ReaderContent.swift` | Pending #50 (and #59/#61/#74) covers ebook main-module composition; no duplicate port. Other caller movement not fully qualified. |
| `Sources/LakeOfFireContent/Resources/CSS/Reader.css` | Genuinely missing ebook selector isolation under data-is-ebook; hotfix provenance 6dc2325b. Not implemented; preserve newer upstream article layout and test rendered ebook effect. |
| `Sources/LakeOfFireContent/Resources/CSS/SwiftReadability.css` | Partially ported: hotfix ebook max-width isolation absent main; retain upstream Japanese strict layout/style policy. Not implemented. |
| `Sources/LakeOfFireContent/Resources/User Scripts/Readability.js` | Unresolved extraction architecture: hotfix uses SwiftReadability resource provider, main bundles local copy. Compare pinned dependency implementation before changing. |
| `Sources/LakeOfFireContent/Resources/User Scripts/readability_images.js` | Intentionally divergent/stronger upstream image management: clears only owned width properties, preserves other inline style; hotfix cssText overwrite is weaker. Ebook early-return exists both. |
| `Sources/LakeOfFireContent/Resources/User Scripts/readability_initialization.template.js` | Unresolved: hotfix removes diagnostics and changes materialization; inspected diff, complete runtime policy not traced. |
| `Sources/LakeOfFireContent/Resources/User Scripts/readability_reader_mode.js` | Unresolved deletion/movement; preserve main until actual consumer/resource composition is proved. |
| `Sources/LakeOfFireContent/Resources/User Scripts/readability_view_original.js` | Unresolved small resource change; final consumer not independently qualified. |
| `Sources/LakeOfFireContent/User Scripts/NetflixUserScript.swift` | Unresolved/likely inactive: hotfix shared aliases ReadabilityImagesUserScript and resource loads netflix; no reachable LibraryConfiguration call established. Do not copy. |
| `Sources/LakeOfFireContent/User Scripts/ReadabilityImagesUserScript.swift` | Intentionally divergent MainActor construction retained for upstream Swift 6; resource caller inspected. |
| `Sources/LakeOfFireContent/User Scripts/ReadabilityScript.swift` | Unresolved resource producer migration; MainActor construction intentionally retained. Source selection local bundle versus SwiftReadability dependency requires dedicated comparison. |
| `Sources/LakeOfFireContent/User Scripts/ReaderConsoleLogsUserScript.swift` | Unresolved diagnostic owner movement; no source port based merely on file absence. |
| `Sources/LakeOfFireContent/User Scripts/ReaderUserScript.swift` | Retired/inert source: hotfix file is entirely commented out; main LibraryConfiguration also comments invocation. No runtime port. |
| `Sources/LakeOfFireContent/User Scripts/YoutubeAdSkipUserScript.swift` | Unresolved reachability/product policy; hotfix script present but no LibraryConfiguration invocation established. No port. |
| `Sources/LakeOfFireContent/Video/MediaStatus.swift` | Unresolved model movement into Core; storage/schema caller integration not reviewed. Media architecture is not a requirement to restore hotfix copies. |
| `Sources/LakeOfFireContent/Web/Bookmark.swift` | Unresolved captured association completion/delete and actor ownership. Main Sendable script descriptor design preserved; no wholesale copy. |
| `Sources/LakeOfFireContent/Web/HistoryRecord.swift` | Partially ported: pending #53/#50 demotion lifecycle cover, canonical aliases already main. Broader captured configurations, demotion committed-state ownership unresolved. |
| `Sources/LakeOfFireContent/Web/UserScript.swift` | Intentionally divergent/stronger upstream immutable WebViewUserScriptDescriptor transport + MainActor assembly, rather than hotfix Realm-bound script production. |
| `Sources/LakeOfFireContentUI/CloudDriveSyncStatusModel.swift` | Unresolved: endpoint ownership/movement inventoried only; full semantic caller review remains open. |
| `Sources/LakeOfFireContentUI/Exports.swift` | Unresolved: endpoint ownership/movement inventoried only; full semantic caller review remains open. |
| `Sources/LakeOfFireContentUI/Reader Content/BookmarkButton.swift` | Unresolved: endpoint ownership/movement inventoried only; full semantic caller review remains open. |
| `Sources/LakeOfFireContentUI/Reader Content/ReaderContentCell.swift` | Pending #54 live annotation stream with cancellation publication check reviewed. Hotfix moved source to Reader; broader list display refresh/seen state unresolved. |
| `Sources/LakeOfFireContentUI/Reader Content/ReaderContentHorizontalList.swift` | Unresolved: endpoint ownership/movement inventoried only; full semantic caller review remains open. |
| `Sources/LakeOfFireContentUI/Reader Content/ReaderContentList.swift` | Pending #50 composes list lifecycle; hotfix moved owner to Reader. Filter/selection and cancellation semantics not fully reviewed. |
| `Sources/LakeOfFireContentUI/Reader Content/ReaderContentSourceIconImage.swift` | Unresolved: endpoint ownership/movement inventoried only; full semantic caller review remains open. |
| `Sources/LakeOfFireContentUI/ReaderImage.swift` | Unresolved: endpoint ownership/movement inventoried only; full semantic caller review remains open. |
| `Sources/LakeOfFireLibrary/Feeds/ContentCategoryButtons.swift` | Unresolved: endpoint ownership/movement inventoried only; full semantic caller review remains open. |
| `Sources/LakeOfFireLibrary/Feeds/FeedCategoryImage.swift` | Unresolved visual backing/transaction changes: hotfix overlays fixed backing and suppresses image animation; no mounted review. |
| `Sources/LakeOfFireLibrary/Feeds/FeedCell.swift` | Intentionally divergent upstream source-icon fallback abstraction retained versus hotfix LakeImage direct call; diagnostics not a forward-port requirement. |
| `Sources/LakeOfFireLibrary/Feeds/FeedView.swift` | Genuinely missing canonical article merge; deferred after selection/collection review. Exact-group subscription replacement, seen state final consumer and request scope remain unresolved. |
| `Sources/LakeOfFireLibrary/Library/CodeEditor.swift` | Intentionally divergent imports only in endpoint diff; CodeEditor behavior same. |
| `Sources/LakeOfFireLibrary/Library/Library Category Buttons/ContentCategoryButtons.swift` | Unresolved: endpoint ownership/movement inventoried only; full semantic caller review remains open. |
| `Sources/LakeOfFireLibrary/Library/Library Category Buttons/EditorsPicksLibraryCategoryButtons.swift` | Unresolved: endpoint ownership/movement inventoried only; full semantic caller review remains open. |
| `Sources/LakeOfFireLibrary/Library/Library Category Buttons/UserLibraryCategoryButtons.swift` | Unresolved: endpoint ownership/movement inventoried only; full semantic caller review remains open. |
| `Sources/LakeOfFireLibrary/Library/LibraryCategoriesView.swift` | Partially ported in pending #95 captured configuration/command behavior; reviewed scope/API, not all final hotfix tail. Presentation identity/editor order and generation replacement still require semantic closure. |
| `Sources/LakeOfFireLibrary/Library/LibraryCategoriesViewModel.swift` | Partially ported in pending #95 captured configuration/command behavior; reviewed scope/API, not all final hotfix tail. Presentation identity/editor order and generation replacement still require semantic closure. |
| `Sources/LakeOfFireLibrary/Library/LibraryCategoryView.swift` | Partially ported in pending #95 captured configuration/command behavior; reviewed scope/API, not all final hotfix tail. Presentation identity/editor order and generation replacement still require semantic closure. |
| `Sources/LakeOfFireLibrary/Library/LibraryDataManager+Categories.swift` | Partially ported in pending #95 captured configuration/command behavior; reviewed scope/API, not all final hotfix tail. Presentation identity/editor order and generation replacement still require semantic closure. |
| `Sources/LakeOfFireLibrary/Library/LibraryFeedView.swift` | Genuinely missing captured feed editor identity/configuration, field ordering, metadata URL/request/revision admission. Not covered #95. Port deferred. |
| `Sources/LakeOfFireLibrary/Library/LibraryManagerView.swift` | Unresolved view identity/lifecycle and presentation ownership; keep main architecture. |
| `Sources/LakeOfFireLibrary/Library/LibraryManagerViewModel.swift` | Partially ported in pending #95 captured configuration/command behavior; reviewed scope/API, not all final hotfix tail. Presentation identity/editor order and generation replacement still require semantic closure. |
| `Sources/LakeOfFireLibrary/Library/LibraryScriptFormSections.swift` | Unresolved captured editor field-order and retire semantics; hotfix adds substantial owner changes beyond #95. |
| `Sources/LakeOfFireLibrary/Library/LibraryScriptsListView.swift` | Partially ported in pending #95 captured configuration/command behavior; reviewed scope/API, not all final hotfix tail. Presentation identity/editor order and generation replacement still require semantic closure. |
| `Sources/LakeOfFireLibrary/Library/UserScriptAllowedDomainCell.swift` | Unresolved: endpoint ownership/movement inventoried only; full semantic caller review remains open. |
| `Sources/LakeOfFireLibrary/Library/WebFeedButton.swift` | Intentionally divergent MainActor and feature imports retained for main Swift 6; deeper feature policy not qualified. |
| `Sources/LakeOfFireContent/Feeds/FeedFollowingEditListBuilder.swift` | Correctly ported byte-identical snapshot/group helper; canonical key producer inspected. No main LibraryManagerViewModel call to this helper found; live usage/reachability unresolved, equality does not prove integration. |
| `Sources/LakeOfFireContent/Resources/User Scripts/dompurify.min.js` | Correctly ported byte-identical vendor resource; ReadabilityScript loads and concatenates sanitizer. Full extraction differences elsewhere remain open. |
| `Sources/LakeOfFireContent/Video/MediaTranscript.swift` | Correctly ported byte-identical hashed transcript model/compression identity; schema v72 cache discard same. Retain stronger upstream transcript registry; broader live source-media consumers not proved. |

Sources/LakeOfFireMedia does not exist at either selected content module layout; current MediaTranscript/main transcript registry plus Reader web-media owners are retained. Do not infer a missing feature solely from the nominal directory.

## Recorded shuffled pass

Seed `20261010`, Python `random.Random(seed).shuffle(sorted review paths)` supplement. The order below is the generated pass order; semantic revisits completed for feed/content/collection boundaries, image script, schema, OPML shim, ReaderContent identity and #54 annotation owner. Paths marked unresolved above remain unqualified; generating a permutation is not review completion.

1. `Sources/LakeOfFireContentUI/Reader Content/ReaderContentHorizontalList.swift`
2. `Sources/LakeOfFireContent/Reader/PlainTextHTMLConverter.swift`
3. `Sources/LakeOfFireContent/User Scripts/ReaderConsoleLogsUserScript.swift`
4. `Sources/LakeOfFireContent/Resources/User Scripts/readability_view_original.js`
5. `Sources/LakeOfFireContent/Reader/ReaderContentLoader.swift`
6. `Sources/LakeOfFireContent/Resources/User Scripts/Readability.js`
7. `Sources/LakeOfFireLibrary/Feeds/ContentCategoryButtons.swift`
8. `Sources/LakeOfFireLibrary/Library/Library Category Buttons/UserLibraryCategoryButtons.swift`
9. `Sources/LakeOfFireLibrary/Feeds/FeedView.swift`
10. `Sources/LakeOfFireLibrary/Feeds/FeedCategoryImage.swift`
11. `Sources/LakeOfFireContent/Resources/User Scripts/readability_initialization.template.js`
12. `Sources/LakeOfFireContentUI/Exports.swift`
13. `Sources/LakeOfFireContent/Reader/ReaderContent.swift`
14. `Sources/LakeOfFireLibrary/Library/Library Category Buttons/ContentCategoryButtons.swift`
15. `Sources/LakeOfFireContent/Resources/CSS/Reader.css`
16. `Sources/LakeOfFireContent/Library/OPMLSendable.swift`
17. `Sources/LakeOfFireContentUI/Reader Content/ReaderContentList.swift`
18. `Sources/LakeOfFireLibrary/Library/UserScriptAllowedDomainCell.swift`
19. `Sources/LakeOfFireContent/Web/Bookmark.swift`
20. `Sources/LakeOfFireLibrary/Library/Library Category Buttons/EditorsPicksLibraryCategoryButtons.swift`
21. `Sources/LakeOfFireContentUI/ReaderImage.swift`
22. `Sources/LakeOfFireContentUI/Reader Content/ReaderContentCell.swift`
23. `Sources/LakeOfFireContent/Reader/ReaderContentProtocol Extensions.swift`
24. `Sources/LakeOfFireContent/Video/MediaStatus.swift`
25. `Sources/LakeOfFireContent/Feeds/Feed Models.swift`
26. `Sources/LakeOfFireLibrary/Library/LibraryDataManager+Categories.swift`
27. `Sources/LakeOfFireLibrary/Library/LibraryManagerViewModel.swift`
28. `Sources/LakeOfFireContent/User Scripts/ReaderUserScript.swift`
29. `Sources/LakeOfFireContent/Library/LibraryDataManager.swift`
30. `Sources/LakeOfFireContentUI/CloudDriveSyncStatusModel.swift`
31. `Sources/LakeOfFireContent/Reader/ReaderContentProtocol.swift`
32. `Sources/LakeOfFireLibrary/Library/LibraryScriptFormSections.swift`
33. `Sources/LakeOfFireContent/Reader/WebViewNavigator+ReaderContent.swift`
34. `Sources/LakeOfFireLibrary/Library/LibraryScriptsListView.swift`
35. `Sources/LakeOfFireContent/Web/HistoryRecord.swift`
36. `Sources/LakeOfFireLibrary/Library/LibraryCategoriesViewModel.swift`
37. `Sources/LakeOfFireContent/Resources/User Scripts/readability_reader_mode.js`
38. `Sources/LakeOfFireContentUI/Reader Content/BookmarkButton.swift`
39. `Sources/LakeOfFireContentUI/Reader Content/ReaderContentSourceIconImage.swift`
40. `Sources/LakeOfFireContent/DefaultRealmConfiguration.swift`
41. `Sources/LakeOfFireContent/Web/UserScript.swift`
42. `Sources/LakeOfFireLibrary/Library/LibraryCategoryView.swift`
43. `Sources/LakeOfFireContent/Reader/ReaderContentTextIngestion.swift`
44. `Sources/LakeOfFireContent/Reader/TranscriptPageRegistry.swift`
45. `Sources/LakeOfFireLibrary/Feeds/FeedCell.swift`
46. `Sources/LakeOfFireLibrary/Library/LibraryFeedView.swift`
47. `Sources/LakeOfFireLibrary/Library/WebFeedButton.swift`
48. `Sources/LakeOfFireContent/User Scripts/NetflixUserScript.swift`
49. `Sources/LakeOfFireContent/User Scripts/YoutubeAdSkipUserScript.swift`
50. `Sources/LakeOfFireContent/User Scripts/ReadabilityImagesUserScript.swift`
51. `Sources/LakeOfFireContent/Resources/User Scripts/readability_images.js`
52. `Sources/LakeOfFireLibrary/Library/LibraryCategoriesView.swift`
53. `Sources/LakeOfFireContent/Library/LibraryConfiguration+Consolidation.swift`
54. `Sources/LakeOfFireLibrary/Library/LibraryManagerView.swift`
55. `Sources/LakeOfFireLibrary/Library/CodeEditor.swift`
56. `Sources/LakeOfFireContent/Resources/CSS/SwiftReadability.css`
57. `Sources/LakeOfFireContent/User Scripts/ReadabilityScript.swift`

## Tests/docs separate accounting and limitations

Inspected existing Asahi parser/network/Realm fixture, ReaderContentLoadCoordinationTests controlled resolver fixture, ReaderContentLoaderAdditionalProviderTests Realm configuration/provider fixture, Package.swift LakeOfFireTests target membership, #95 captured/observer/prepared-OPML suites and #54 annotation-observer suite. Existing tests were treated as source coverage intentions, not execution. New tests above cover selected focused ports only.

The following directly relevant dated test inventory still needs full method-by-method reconciliation (excluding Files/book-import suites owned elsewhere):

- `Tests/LakeOfFireTests/AsahiFeedReadabilityPipelineTests.swift`
- `Tests/LakeOfFireTests/FeedDecodingTests.swift`
- `Tests/LakeOfFireTests/FeedDirectoryTests.swift`
- `Tests/LakeOfFireTests/FeedStateIndicatorTests.swift`
- `Tests/LakeOfFireTests/HistoryDemotionCommittedStateTests.swift`
- `Tests/LakeOfFireTests/LibraryCategoryPresentationTests.swift`
- `Tests/LakeOfFireTests/LibraryConfigurationActorBoundaryTests.swift`
- `Tests/LakeOfFireTests/LibraryConfigurationConsolidationTests.swift`
- `Tests/LakeOfFireTests/LibraryEditorRetirementTests.swift`
- `Tests/LakeOfFireTests/LibraryExportPresentationTests.swift`
- `Tests/LakeOfFireTests/LibraryFeedEditorOwnershipTests.swift`
- `Tests/LakeOfFireTests/LibraryRegressionTests.swift`
- `Tests/LakeOfFireTests/ReaderBuiltInUserScriptsTests.swift`
- `Tests/LakeOfFireTests/ReaderContentCellAnnotationObservationTests.swift`
- `Tests/LakeOfFireTests/ReaderContentInitialImageRendererTests.swift`
- `Tests/LakeOfFireTests/ReaderContentListSnapshotTests.swift`
- `Tests/LakeOfFireTests/ReaderContentLoadCoordinationTests.swift`
- `Tests/LakeOfFireTests/ReaderContentLoaderAdditionalProviderTests.swift`
- `Tests/LakeOfFireTests/ReaderContentLoadingOwnershipTests.swift`
- `Tests/LakeOfFireTests/ReaderContentLoadingStorageTests.swift`
- `Tests/LakeOfFireTests/ReaderImageRequestTests.swift`
- `Tests/LakeOfFireTests/ReaderSnippetPipelineDiagnosticsTests.swift`
- `Tests/LakeOfFireTests/ReaderSnippetProcessingTests.swift`
- `Tests/LakeOfFireTests/ReaderSnippetTitleTests.swift`
- `Tests/LakeOfFireTests/WikipediaReadabilityRegressionTests.swift`

Docs: root HOTFIX-PORT history-miss/source-known body/Atom lists/merged FeedView claims rechecked against endpoints; focused WIP plus deferred merge recorded here; root ledger read-only. Pending #54/#50/#95 port docs are pending evidence only. No shared or owned repo docs changed; this external report preserves exact remaining scope.

Highest next work: (1) ReaderContent cached/preloaded/completed selection ownership + durable title commands; (2) library feed/script editor captured identity, final field ordering and metadata lease, immutable consolidation; (3) complete feed authoritative payload/enrichment partition, request/config/account generations, true no-op filtering and durable mirror debt, group subscription replacement and seen final consumer; (4) source extraction producer resource and ebook stylesheet qualification; (5) every unresolved source path and existing tests above. Mounted collection/selection/platform tests, cold reopen/journal precision and suspended history miss remain unexecuted/uncovered. No full audit closure or published port claim.
