# LakeOfFire files, books and catalogs audit — 2026-10-10

Assigned owner paths: `Sources/LakeOfFireContent/Files`, `Sources/LakeOfFireFiles`, `Sources/LakeOfFireReader/Reader/Books`, and `Sources/LakeOfFireOPDS`. There is no `LakeOfFireBooks` module. Work is bounded to the frozen dated hotfix inventory, 2025-10-10 through 2026-10-10 inclusive. This is a partial audit, not global closure.

Hotfix selected pin: `036d4193078016db0becdf91b86dd34fb1d579e0`. Main target: `8985bf92b9504d53e00025e4054b3aa97f876e45`. Source repository: https://github.com/lake-of-fire/LakeOfFire. Dirty original checkouts were not used as endpoint evidence or edited. No repository AGENTS.md was found; task instructions and Reader AGENTS.md were read, along with reconcile-hotfix-upstream and maintain-bigsync-realm.

## Verified change left unstaged

`ReaderFileManager.initialize(ubiquityContainerIdentifier:)` previously published the identifier before either asynchronous drive constructor completed, used `try?` for required local preparation, and launched unobserved initial refresh work. All ten pending non-v3-hotfix heads below retain that legacy preparation (including #50 and its #59/#61/#74 continuations). Hotfix provenance: `918305e33bd3cce88eb9e1b2df7fca457d45a30b` introduces atomic preparation; `883fa0ac0104ad197b34362ba642f76d96c74a4d` adds replacement admission, present at the selected hotfix pin.

Adapted main in `Sources/LakeOfFireContent/Files/ReaderFileManager.swift`: preserve the existing injected cold-start root provider; add instance drive factories; reject already-cancelled entrants before replacing UUID ownership; prepare optional cloud and required local drives; validate the exact attempt before observer attachment and publication; publish the complete tuple without triggering the identifier observer; retain legacy background refresh as a separately unresolved boundary. Initialization success acknowledges drive preparation only, not inventory completion. Local failure and cancellation preserve the previously installed tuple. A failed newer attempt does not readmit an older attempt.

Live caller: `ReaderEnvironmentViewModifier.swift` / `ReaderFileManagerModifier.body` invokes initialization from `.task(id: ubiquityContainerIdentifier)` and assigns the shared manager before awaiting; no caller API changes are needed. `ReaderFileManagerSetupModifier` retains its main-actor update handler. Public initializers remain compatible; the preexisting internal root-provider initializer accepts optional factory hooks.

New runtime source `Tests/LakeOfFireTests/ReaderFileInitializationOwnershipTests.swift` owns four deterministic contracts: cancelled entry invokes no factories; cancellation while cloud preparation is suspended leaves installed identifier unchanged; required local failure propagates without publication; failed newer preparation permanently revokes older cloud work. Tests use actor continuations and exercise actual manager methods, not source text. Existing package `LakeOfFireTests` path automatically includes this file and already depends on LakeOfFireContent. **Not run by request**; no builds, tests, benchmarks, generators, native apps, installs or CI dispatch ran. Only assigned `git diff --check` was run and passed.

Limit: this is preparation/publication admission, not a complete storage-selection port. Main still has a global inventory task and no captured-selection write fence. Cancellation/replacement after tuple publication can leave that scan running, and same-drive/configuration inventory delivery requires the separate missing queue/admission work. An independent review confirmed that awaiting the legacy refresh can join an obsolete scan or debounce-skip the new tuple. The proposed await was removed; the final implementation makes no inventory-settlement promise. Successful replacement scan fencing remains missing.

## Findings and pending coverage

- **P1 genuinely missing:** lossless scope-keyed inventory queue, per-batch caller completion, late-waiter cancellation, suspension replay preserving force, and final storage/Realm/initialization admission. Hotfix `7cdfe17a6a7877bcb1b56cdfabc69070d3f2fca2` and the later queue/admission commits implement this; main and #50 retain debounce/task machinery. `ReaderFileRefreshQueue.swift` is absent from main and #50. Do not copy the queue without adapting `refreshAllFilesMetadata`, observer delivery, captured Realm writes, read/import/download selection, and deletion owners. Deletion tests and active deletion branch were not edited.

- **P1 covered only by pending upstream PRs, not main:** collision-safe imports (#51 and #50), retryable import result presentation, downloadable row lifetime/identity, catalog fetch lifetime, and document-bound package sessions (#50). #50 `DownloadableBookGridCell.importIdentity` is preserved untouched: remote URL, local destination and title reset row state and revoke obsolete imports. #50 `BookDownloadOperation` checks ownership before publication and protects explicit selection from passive refresh; transplanting the older hotfix outcome helper would lose that architecture.

- **P1 partial pending coverage:** hotfix `ReaderEBookPackageFingerprint`/`ReaderEBookZIPDirectory` accept and validate deflated empty directory entries. #50 rejects any directory with nonzero compressed size; its ZIP preflight lacks `validateEmptyDeflate`. This is a concrete compatibility gap against the pending session pipeline. Main lacks these session/fingerprint owners, so it needs adaptation after #50 composition rather than a standalone file copy.

- **P1 genuinely missing:** `ReaderFileStoragePaths` source-owned download slots and encoded final-component validation. Hotfix `64fa9d3e88617914192ac17cd08c961c7d22804b`, subsequently `01e62a11`, hashes resource identity retaining query and excluding fragment; validates decoded filename exactly once and delegates staging detection to SwiftUIDownloads. Main/#50 do not contain this helper. Needs the live `downloadable` destination and shared download contract adapted together.

- **P1 genuinely missing/needs adaptation:** retryable specialized EPUB enrichment and metadata write admission. Main `EbookFileManager.configure` collects live managed objects after availability awaits and `applyMetadataUpdates` writes a selected first Realm; hotfix `9206fbb72ef0157763cc93bb7c858668b8b484ed` carries immutable prepared values, original field observations and per-Realm re-resolution; `ReaderFileManager.fileEnrichmentProcessors` preserves retry IDs. Main/#50 do not expose that registry. Preserve main XML/date semantics when adapting.

- **P1 metadata gap implemented locally, unverified:** main XML parser has direct namespace/depth/package-graph checks and reduced-precision dates; hotfix metadata now adds CDATA callbacks, first nonempty title/creator selection, explicit EPUB main-title refinement, and entity-declaration rejection. Main selects the first title/creator at element start even if empty, and has no foundCDATA callback. #50 only adds resource limits to this parser and does not repair these semantics. These were adapted locally in EPubParser.swift: accept the first nonempty title/creator, prefer a direct correctly namespaced main-title refinement, forward UTF-8 CDATA into active capture, and abort both container/package parsers on internal or external entity declarations. Existing namespace/depth/package-graph checks and reduced-precision date logic remain intact. Nine runtime tests were authored in EPubMetadataSelectionTests.swift; not run by request. Whole-parser replacement was avoided.

- **Correctly ported/stronger pending:** #48 OPDS document scoping, redirect-aware URL resolution, HTTP response admission and OpenSearch template parsing cover the hotfix parser behavior. #48 additionally transfers fresh ParseData using `sending`, supplies cancellation-owned async URLSession transport and snapshots mutable metadata before callbacks. Preserve #48; hotfix callbacks are older Swift concurrency shape. Main has neither HTTP admission nor the async entry point.

- **Main stronger; retain:** Archive+Data directory reads use `openat` with `O_NOFOLLOW`, root device/inode identity and regular-file validation; archive source freshness checks and LRU caching reject replacement. #50 adds bounded resource limits around this owner. Never replace this with the shorter hotfix package source. Main `OPDSCatalog` explicitly conforms to ChangeMetadataRecordable and returns a no-op softDelete result; additions refresh metadata after Realm insertion in the same transaction. Hotfix import-only/conformance changes are not a reason to regress these. Full account/configuration lifecycle remains unresolved.

- **Unresolved:** large EbookURLSchemeHandler and EbookHTMLResponseMetadata differences include newer main durable sidecar/UTF-16 policies, #50 session capability composition and hotfix serving/runtime work. This pass traced package transport owner symbols and cancellation terminals, but did not complete endpoint-by-endpoint sidecar/processing/presentation semantics. Do not label these entirely ported.

## Pending heads compared

| PR | Base | Frozen head | Relevance |
|---|---|---|---|
| [#95](https://github.com/lake-of-fire/LakeOfFire/pull/95) | main | `21c42ff0138c0b5b934956cbcccd107e5c577cf6` | Initialization owner checked; other slice work preserved |
| [#74](https://github.com/lake-of-fire/LakeOfFire/pull/74) | port/epub-serving-safety-integration-20260928 | `ad19065bd567f09f64a7f321feb2087fd60701fa` | Direct file/book/session/catalog port |
| [#61](https://github.com/lake-of-fire/LakeOfFire/pull/61) | port/epub-serving-safety-integration-20260928 | `0dc1e429fc8e2d2b7e7f2a176fe2f72fabc7ab9e` | Direct file/book/session/catalog port |
| [#59](https://github.com/lake-of-fire/LakeOfFire/pull/59) | port/epub-serving-safety-integration-20260928 | `0dd0b07afac69c6d02512a7b02ff2acb27bf7bb0` | Direct file/book/session/catalog port |
| [#54](https://github.com/lake-of-fire/LakeOfFire/pull/54) | main | `28c6911ada2221bc9a390de65f31b79bfba84bd4` | Initialization owner checked; other slice work preserved |
| [#53](https://github.com/lake-of-fire/LakeOfFire/pull/53) | main | `35e0a7e65ce63365a9923a92fac832ad087c549b` | Initialization owner checked; other slice work preserved |
| [#51](https://github.com/lake-of-fire/LakeOfFire/pull/51) | main | `547b1e88a836c8c4b53c24c98294700e9066a745` | Direct file/book/session/catalog port |
| [#50](https://github.com/lake-of-fire/LakeOfFire/pull/50) | main | `0b91431f0fe04c45b24b08b427a5df66e87661b9` | Direct file/book/session/catalog port |
| [#48](https://github.com/lake-of-fire/LakeOfFire/pull/48) | main | `2f3a63733583e179bddc8025a7320141fc1ddade` | Direct file/book/session/catalog port |
| [#41](https://github.com/lake-of-fire/LakeOfFire/pull/41) | main | `af14b895d9d3e1a1fe8c3a00e52c158d6eae211e` | Direct file/book/session/catalog port |

Excluded as upstream coverage: [#137](https://github.com/lake-of-fire/LakeOfFire/pull/137) (`8b9d8381ce7561625452545b99260b29aaf81f37`) and #113 (`9ef23abaecf93eb24dfbe55cbf02e9598f4f935f`) both target v3-hotfix. #137 Books observation may be useful future evidence but is not selected by the frozen hotfix pin and was not applied.

## Exact dated source-path accounting

47 unique eligible source paths. Each row records current disposition and depth. An equality column is mechanical blob equality at the specified PR head; it does not prove main or root integration. No source inventory path is silently omitted.

| Path | Disposition and reviewed boundary | Exact hotfix equality at pending heads |
|---|---|---|
| `Sources/LakeOfFireContent/Files/Archive+Data.swift` | Unresolved complete semantic reconciliation; current main owner architecture and key package/cancellation safety traced, not all routes. | none |
| `Sources/LakeOfFireContent/Files/ContentFile.swift` | Intentional architecture divergence; main deletion/journal conformance and no-op behavior retained; deletion lifecycle separate owner. | none |
| `Sources/LakeOfFireContent/Files/ContentPackageFile.swift` | Correctly ported behavior or intentional module split; import/access-level/copy-only delta reviewed; epubZip lives in Core UTType+EPub. | none |
| `Sources/LakeOfFireContent/Files/PhysicalMediaCapableProtocol.swift` | Correctly ported behavior or intentional module split; import/access-level/copy-only delta reviewed; epubZip lives in Core UTType+EPub. | none |
| `Sources/LakeOfFireContent/Files/ReaderEBookDirectorySnapshotArchive.swift` | Absent main, pending #50 session/fingerprint family; equality checked and owner traced; complete integration semantics unresolved. | #74, #61, #59, #50 |
| `Sources/LakeOfFireContent/Files/ReaderEBookInitialRestorePolicy.swift` | Absent main, pending #50 session/fingerprint family; equality checked and owner traced; complete integration semantics unresolved. | #74, #61, #59, #50, #41 |
| `Sources/LakeOfFireContent/Files/ReaderEBookLocalAvailability.swift` | Absent main, pending #50 session/fingerprint family; equality checked and owner traced; complete integration semantics unresolved. | #74, #61, #59, #50 |
| `Sources/LakeOfFireContent/Files/ReaderEBookPackageFingerprint.swift` | Partial pending #50; deflated empty-directory delta inspected; full fingerprint qualification unresolved. | none |
| `Sources/LakeOfFireContent/Files/ReaderEBookPackageNamespace.swift` | Absent main, pending #50 session/fingerprint family; equality checked and owner traced; complete integration semantics unresolved. | #74, #61, #59, #50 |
| `Sources/LakeOfFireContent/Files/ReaderEBookPackageSnapshot.swift` | Absent main, pending #50 session/fingerprint family; equality checked and owner traced; complete integration semantics unresolved. | none |
| `Sources/LakeOfFireContent/Files/ReaderEBookRenditionSelection.swift` | Absent main, pending #50 session/fingerprint family; equality checked and owner traced; complete integration semantics unresolved. | #74, #61, #59, #50 |
| `Sources/LakeOfFireContent/Files/ReaderEBookServingSession.swift` | Absent main, pending #50 session/fingerprint family; equality checked and owner traced; complete integration semantics unresolved. | none |
| `Sources/LakeOfFireContent/Files/ReaderEBookSnapshotFingerprint.swift` | Absent main, pending #50 session/fingerprint family; equality checked and owner traced; complete integration semantics unresolved. | #74, #61, #59, #50 |
| `Sources/LakeOfFireContent/Files/ReaderEBookZIPDirectory.swift` | Partial pending #50; deflated empty-directory delta inspected; full fingerprint qualification unresolved. | none |
| `Sources/LakeOfFireContent/Files/ReaderFileImportPresentation.swift` | Partial main; behavior adaptation in #50/#51 inspected; imported-state/collision/presentation owner verified pending only. | none |
| `Sources/LakeOfFireContent/Files/ReaderFileImportStorage.swift` | Partial main; behavior adaptation in #50/#51 inspected; imported-state/collision/presentation owner verified pending only. | none |
| `Sources/LakeOfFireContent/Files/ReaderFileManager.swift` | Partially ported; initialization implemented locally; refresh/selection/inventory writes remain missing. | none |
| `Sources/LakeOfFireContent/Files/ReaderFileOperationErrors.swift` | Correctly ported behavior or intentional module split; import/access-level/copy-only delta reviewed; epubZip lives in Core UTType+EPub. | none |
| `Sources/LakeOfFireContent/Files/ReaderFileRefreshQueue.swift` | Genuinely missing; queue completion, replay, force and waiter cancellation reviewed in full. | none |
| `Sources/LakeOfFireContent/Files/ReaderFileStoragePaths.swift` | Genuinely missing; identity/one-decode filename/staging contracts reviewed in full. | none |
| `Sources/LakeOfFireContent/Files/URL+ReaderFileURL.swift` | Correctly ported behavior or intentional module split; import/access-level/copy-only delta reviewed; epubZip lives in Core UTType+EPub. | none |
| `Sources/LakeOfFireFiles/Files/ReaderFileDocumentLoader.swift` | Intentionally divergent helper shape; main handler resolves primary key MIME on its owning actor; dedicated extraction not necessary. | none |
| `Sources/LakeOfFireFiles/Files/ReaderFileManagerSetupModifier.swift` | Correctly ported behavior or intentional module split; import/access-level/copy-only delta reviewed; epubZip lives in Core UTType+EPub. | none |
| `Sources/LakeOfFireFiles/Files/ReaderFileURLSchemeHandler.swift` | Correctly ported task object-identity completion and package MIME; inline ordinary file actor-safe metadata replaces hotfix loader seam. | none |
| `Sources/LakeOfFireFiles/Files/SharedReaderFontAsset.swift` | Correctly ported font routing/CORS behavior; main retains internal visibility and no-op diagnostic shape; tests reconciled. | none |
| `Sources/LakeOfFireOPDS/OPDS1Parser.swift` | Partial main, pending #48 correctly adapts hotfix; transport and URL boundaries inspected; full method-level parser audit incomplete. | none |
| `Sources/LakeOfFireOPDS/OPDS2Parser.swift` | Partial main, pending #48 correctly adapts hotfix; transport and URL boundaries inspected; full method-level parser audit incomplete. | none |
| `Sources/LakeOfFireOPDS/OPDSModels.swift` | Partial main, pending #48 correctly adapts hotfix; transport and URL boundaries inspected; full method-level parser audit incomplete. | none |
| `Sources/LakeOfFireOPDS/OPDSParser.swift` | Partial main, pending #48 correctly adapts hotfix; transport and URL boundaries inspected; full method-level parser audit incomplete. | none |
| `Sources/LakeOfFireOPDS/URLHelper.swift` | Partial main, pending #48 correctly adapts hotfix; transport and URL boundaries inspected; full method-level parser audit incomplete. | #74, #61, #59, #50, #48 |
| `Sources/LakeOfFireReader/Reader/Books/Book Views.swift` | Partial main; behavior adaptation in #50/#51 inspected; imported-state/collision/presentation owner verified pending only. | none |
| `Sources/LakeOfFireReader/Reader/Books/BookDownloadImportAttempt.swift` | Partial main; behavior adaptation in #50/#51 inspected; imported-state/collision/presentation owner verified pending only. | none |
| `Sources/LakeOfFireReader/Reader/Books/BookGridCell.swift` | Partial main; behavior adaptation in #50/#51 inspected; imported-state/collision/presentation owner verified pending only. | none |
| `Sources/LakeOfFireReader/Reader/Books/BookLibraryView.swift` | Partial main; behavior adaptation in #50/#51 inspected; imported-state/collision/presentation owner verified pending only. | none |
| `Sources/LakeOfFireReader/Reader/Books/Document+Ebooks.swift` | Correctly ported behavior or intentional module split; import/access-level/copy-only delta reviewed; epubZip lives in Core UTType+EPub. | none |
| `Sources/LakeOfFireReader/Reader/Books/EPub.swift` | Correctly ported behavior or intentional module split; import/access-level/copy-only delta reviewed; epubZip lives in Core UTType+EPub. | none |
| `Sources/LakeOfFireReader/Reader/Books/EPubMetadataDocument.swift` | EPubParser metadata selection/declaration gaps implemented locally; namespace/depth/date main retained. Hotfix EPubMetadataDocument helper shape intentionally not copied; full additional package/cover compatibility unresolved. | none |
| `Sources/LakeOfFireReader/Reader/Books/EPubParser.swift` | EPubParser metadata selection/declaration gaps implemented locally; namespace/depth/date main retained. Hotfix EPubMetadataDocument helper shape intentionally not copied; full additional package/cover compatibility unresolved. | none |
| `Sources/LakeOfFireReader/Reader/Books/EbookEntryPathTransport.swift` | Absent main, pending #50 session/fingerprint family; equality checked and owner traced; complete integration semantics unresolved. | #74, #61, #59, #50 |
| `Sources/LakeOfFireReader/Reader/Books/EbookFileManager.swift` | Partial main; stronger hotfix field/Realm/enrichment admission missing; mutation and availability callers inspected. | none |
| `Sources/LakeOfFireReader/Reader/Books/EbookHTMLResponseMetadata.swift` | Unresolved complete semantic reconciliation; current main owner architecture and key package/cancellation safety traced, not all routes. | none |
| `Sources/LakeOfFireReader/Reader/Books/EbookPackageSessionEnvironment.swift` | Absent main, pending #50 session/fingerprint family; equality checked and owner traced; complete integration semantics unresolved. | #74, #61, #59, #50 |
| `Sources/LakeOfFireReader/Reader/Books/EbookURLSchemeHandler.swift` | Unresolved complete semantic reconciliation; current main owner architecture and key package/cancellation safety traced, not all routes. | none |
| `Sources/LakeOfFireReader/Reader/Books/HostedBookResourceQualification.swift` | Intentionally retired qualification resource accessor; no production port justified. | none |
| `Sources/LakeOfFireReader/Reader/Books/OPDS/OPDS Models.swift` | Intentional architecture divergence; main deletion/journal conformance and no-op behavior retained; deletion lifecycle separate owner. | none |
| `Sources/LakeOfFireReader/Reader/Books/OPDS/OPDSCatalogsView.swift` | Absent main, pending #50 session/fingerprint family; equality checked and owner traced; complete integration semantics unresolved. | none |
| `Sources/LakeOfFireReader/Reader/Books/ReaderEBookInitialization.swift` | Absent main, pending #50 session/fingerprint family; equality checked and owner traced; complete integration semantics unresolved. | #74, #61, #59, #50 |

## Test-path accounting

45 unique directly related dated test paths were inventoried separately. Existing method names and presence were compared for all. This is not full method-by-method behavioral reconciliation. No tests were executed. Book deletion methods inside mixed suites remain externally owned and untouched.

| Path | Disposition |
|---|---|
| `Tests/LakeOfFireOPDSTests/OPDSDocumentBoundaryTests.swift` | Pending #48 suite ownership; transport/scoping/search contracts compared at family level; full method body reconciliation unresolved. |
| `Tests/LakeOfFireOPDSTests/OPDSTransportAndSearchBoundaryTests.swift` | Pending #48 suite ownership; transport/scoping/search contracts compared at family level; full method body reconciliation unresolved. |
| `Tests/LakeOfFireOPDSTests/opds_parser_url_test.swift` | Pending #48 suite ownership; transport/scoping/search contracts compared at family level; full method body reconciliation unresolved. |
| `Tests/LakeOfFireOPDSTests/opensearch_test.swift` | Pending #48 suite ownership; transport/scoping/search contracts compared at family level; full method body reconciliation unresolved. |
| `Tests/LakeOfFireOPDSTests/readium_opds1_1_test.swift` | Pending #48 suite ownership; transport/scoping/search contracts compared at family level; full method body reconciliation unresolved. |
| `Tests/LakeOfFireOPDSTests/readium_opds2_0_test.swift` | Pending #48 suite ownership; transport/scoping/search contracts compared at family level; full method body reconciliation unresolved. |
| `Tests/LakeOfFireTests/BookOpenSelectionOwnershipTests.swift` | Inventoried methods/presence only; runtime contract relevance identified, full body reconciliation remains unresolved. Not modified. |
| `Tests/LakeOfFireTests/DownloadableBookLibraryImportTests.swift` | Main-only stronger runtime suite retained; source presence is not execution. Full body reconciliation unresolved. |
| `Tests/LakeOfFireTests/EBookRenderReadyNativeIntegrationTests.swift` | Inventoried methods/presence only; runtime contract relevance identified, full body reconciliation remains unresolved. Not modified. |
| `Tests/LakeOfFireTests/EPubMetadataDocumentTests.swift` | Inventoried methods/presence only; runtime contract relevance identified, full body reconciliation remains unresolved. Not modified. |
| `Tests/LakeOfFireTests/EPubMetadataPackageTests.swift` | Inventoried methods/presence only; runtime contract relevance identified, full body reconciliation remains unresolved. Not modified. |
| `Tests/LakeOfFireTests/EPubMetadataReadLimitsTests.swift` | Inventoried methods/presence only; runtime contract relevance identified, full body reconciliation remains unresolved. Not modified. |
| `Tests/LakeOfFireTests/EbookEntryPathTransportTests.swift` | Inventoried methods/presence only; runtime contract relevance identified, full body reconciliation remains unresolved. Not modified. |
| `Tests/LakeOfFireTests/EbookMetadataEnrichmentTests.swift` | Inventoried methods/presence only; runtime contract relevance identified, full body reconciliation remains unresolved. Not modified. |
| `Tests/LakeOfFireTests/EbookServingHandlerTests.swift` | Inventoried methods/presence only; runtime contract relevance identified, full body reconciliation remains unresolved. Not modified. |
| `Tests/LakeOfFireTests/EbookURLSchemeHandlerTests.swift` | Inventoried methods/presence only; runtime contract relevance identified, full body reconciliation remains unresolved. Not modified. |
| `Tests/LakeOfFireTests/ReaderContentEbookInitialRestoreResultTests.swift` | Main-only stronger runtime suite retained; source presence is not execution. Full body reconciliation unresolved. |
| `Tests/LakeOfFireTests/ReaderEBookCoordinatedSnapshotTests.swift` | Inventoried methods/presence only; runtime contract relevance identified, full body reconciliation remains unresolved. Not modified. |
| `Tests/LakeOfFireTests/ReaderEBookFingerprintValidationTests.swift` | Inventoried methods/presence only; runtime contract relevance identified, full body reconciliation remains unresolved. Not modified. |
| `Tests/LakeOfFireTests/ReaderEBookInitialRestorePolicyTests.swift` | Inventoried methods/presence only; runtime contract relevance identified, full body reconciliation remains unresolved. Not modified. |
| `Tests/LakeOfFireTests/ReaderEBookInitializationTests.swift` | Inventoried methods/presence only; runtime contract relevance identified, full body reconciliation remains unresolved. Not modified. |
| `Tests/LakeOfFireTests/ReaderEBookLocalAvailabilityTests.swift` | Inventoried methods/presence only; runtime contract relevance identified, full body reconciliation remains unresolved. Not modified. |
| `Tests/LakeOfFireTests/ReaderEBookNamespaceIntegrationTests.swift` | Inventoried methods/presence only; runtime contract relevance identified, full body reconciliation remains unresolved. Not modified. |
| `Tests/LakeOfFireTests/ReaderEBookPackageFingerprintTests.swift` | Inventoried methods/presence only; runtime contract relevance identified, full body reconciliation remains unresolved. Not modified. |
| `Tests/LakeOfFireTests/ReaderEBookPackageNamespaceTests.swift` | Inventoried methods/presence only; runtime contract relevance identified, full body reconciliation remains unresolved. Not modified. |
| `Tests/LakeOfFireTests/ReaderEBookPackageSnapshotTests.swift` | Inventoried methods/presence only; runtime contract relevance identified, full body reconciliation remains unresolved. Not modified. |
| `Tests/LakeOfFireTests/ReaderEBookRenditionSelectionTests.swift` | Inventoried methods/presence only; runtime contract relevance identified, full body reconciliation remains unresolved. Not modified. |
| `Tests/LakeOfFireTests/ReaderEBookServingSessionTests.swift` | Inventoried methods/presence only; runtime contract relevance identified, full body reconciliation remains unresolved. Not modified. |
| `Tests/LakeOfFireTests/ReaderEBookZIPDirectoryTests.swift` | Inventoried methods/presence only; runtime contract relevance identified, full body reconciliation remains unresolved. Not modified. |
| `Tests/LakeOfFireTests/ReaderEBookZIPPathFingerprintTests.swift` | Inventoried methods/presence only; runtime contract relevance identified, full body reconciliation remains unresolved. Not modified. |
| `Tests/LakeOfFireTests/ReaderEBookZIPPathMetadataTests.swift` | Inventoried methods/presence only; runtime contract relevance identified, full body reconciliation remains unresolved. Not modified. |
| `Tests/LakeOfFireTests/ReaderFileInitializationTests.swift` | Hotfix 9 preparation/queue tests reviewed; four main-compatible preparation regressions authored in new Ownership suite. Queue and successful replacement coverage still missing. |
| `Tests/LakeOfFireTests/ReaderFileInventoryAdmissionTests.swift` | Inventoried methods/presence only; runtime contract relevance identified, full body reconciliation remains unresolved. Not modified. |
| `Tests/LakeOfFireTests/ReaderFileLibraryBoundaryTests.swift` | Inventoried methods/presence only; runtime contract relevance identified, full body reconciliation remains unresolved. Not modified. |
| `Tests/LakeOfFireTests/ReaderFileManagerNormalizationTests.swift` | Inventoried methods/presence only; runtime contract relevance identified, full body reconciliation remains unresolved. Not modified. |
| `Tests/LakeOfFireTests/ReaderFileRefreshQueueTests.swift` | Inventoried methods/presence only; runtime contract relevance identified, full body reconciliation remains unresolved. Not modified. |
| `Tests/LakeOfFireTests/ReaderFileStoragePathsTests.swift` | Inventoried methods/presence only; runtime contract relevance identified, full body reconciliation remains unresolved. Not modified. |
| `Tests/LakeOfFireTests/ReaderPackageEntrySourceTests.swift` | Main-only stronger runtime suite retained; source presence is not execution. Full body reconciliation unresolved. |
| `Tests/LakeOfFireTests/ReviewBookDownloadImportOutcomeTests.swift` | Inventoried methods/presence only; runtime contract relevance identified, full body reconciliation remains unresolved. Not modified. |
| `Tests/LakeOfFireTests/ReviewFileImportPresentationTests.swift` | Inventoried methods/presence only; runtime contract relevance identified, full body reconciliation remains unresolved. Not modified. |
| `Tests/LakeOfFireTests/ReviewReaderFileImportTests.swift` | Inventoried methods/presence only; runtime contract relevance identified, full body reconciliation remains unresolved. Not modified. |
| `Tests/LakeOfFireTests/ReviewReaderFileRealmTransferTests.swift` | Inventoried methods/presence only; runtime contract relevance identified, full body reconciliation remains unresolved. Not modified. |
| `Tests/LakeOfFireTests/ReviewReaderStorageSafetyTests.swift` | Inventoried methods/presence only; runtime contract relevance identified, full body reconciliation remains unresolved. Not modified. |
| `Tests/LakeOfFireTests/SharedReaderFontTests.swift` | Current contracts inspected: font routing/fallback/CORS and independent completion identity/terminal cancellation. Extra hotfix package MIME case not executed. |
| `Tests/LakeOfFireTests/URLSchemeTaskCompletionOwnershipTests.swift` | Current contracts inspected: font routing/fallback/CORS and independent completion identity/terminal cancellation. Extra hotfix package MIME case not executed. |

New test sources outside hotfix inventory: `Tests/LakeOfFireTests/ReaderFileInitializationOwnershipTests.swift` (four methods) and `Tests/LakeOfFireTests/EPubMetadataSelectionTests.swift` (nine methods); package source ownership verified statically, discovery/execution unverified. Metadata tests create actual directory-backed EPUB packages and call production parseMetadataAndCover; they cover nonempty selection, Japanese CDATA/escaped entities, explicit main-title precedence, foreign/nested refinement rejection, empty failure, package/container entity declarations, and retained reduced-precision date and duplicate metadata-graph rejection. Tests/Portable runners, Tools scripts and CI workflows were not executed, restored or edited; runner retirement belongs to root configuration owner. This slice has not completed reviewing those auxiliary artifacts.

## Documentation and auxiliary artifacts

Four EPUB design documents in the eligible inventory (`Documentation/epub-identity-namespace-20260925.md`, `epub-initialization-ownership-20260928.md`, `epub-package-fingerprint-20260925.md`, `epub-serving-integration-20260926.md`) are historical hotfix evidence, not current proof. Their detailed narrative reconciliation is unresolved. `Documentation/QualificationEvidence/*` and deletion qualification notes are historical qualification bookkeeping; do not restore them into main. Primary task audit belongs to the parent. No owned gap document existed in this checkout, and no shared root report was edited.

## Reproducible shuffled follow-up

Deterministic pass followed owner chains: manager initialization → SwiftUI caller; import/download → row outcome; OPDS parser → catalog consumer; package snapshot/fingerprint → serving lease → entry handler; metadata parse → actor enrichment write. Shuffled supplement used Python `random.Random(20261010).shuffle` on lexically ordered frozen source inventory. It rechecked presence, symbol relocation and exact pending equality for all 47 paths; the symbol/presence pass is not counted as deeper semantic closure. Findings from supplement: directory compression delta and sourceVersionToken remain hotfix-only; main metadata parser consumes empty first title; helper deletion is not automatically a behavioral omission; qualifier accessor is not production. Order:

1. `Sources/LakeOfFireReader/Reader/Books/EbookEntryPathTransport.swift`
2. `Sources/LakeOfFireOPDS/OPDS2Parser.swift`
3. `Sources/LakeOfFireFiles/Files/SharedReaderFontAsset.swift`
4. `Sources/LakeOfFireContent/Files/ReaderFileOperationErrors.swift`
5. `Sources/LakeOfFireOPDS/OPDSParser.swift`
6. `Sources/LakeOfFireReader/Reader/Books/EbookPackageSessionEnvironment.swift`
7. `Sources/LakeOfFireReader/Reader/Books/BookLibraryView.swift`
8. `Sources/LakeOfFireContent/Files/ReaderFileImportStorage.swift`
9. `Sources/LakeOfFireContent/Files/ReaderEBookZIPDirectory.swift`
10. `Sources/LakeOfFireReader/Reader/Books/BookDownloadImportAttempt.swift`
11. `Sources/LakeOfFireOPDS/OPDSModels.swift`
12. `Sources/LakeOfFireContent/Files/ReaderEBookPackageFingerprint.swift`
13. `Sources/LakeOfFireReader/Reader/Books/BookGridCell.swift`
14. `Sources/LakeOfFireReader/Reader/Books/EPubParser.swift`
15. `Sources/LakeOfFireContent/Files/ReaderEBookDirectorySnapshotArchive.swift`
16. `Sources/LakeOfFireContent/Files/ReaderEBookSnapshotFingerprint.swift`
17. `Sources/LakeOfFireReader/Reader/Books/Book Views.swift`
18. `Sources/LakeOfFireContent/Files/ReaderEBookPackageNamespace.swift`
19. `Sources/LakeOfFireReader/Reader/Books/EbookFileManager.swift`
20. `Sources/LakeOfFireContent/Files/ContentFile.swift`
21. `Sources/LakeOfFireReader/Reader/Books/HostedBookResourceQualification.swift`
22. `Sources/LakeOfFireContent/Files/PhysicalMediaCapableProtocol.swift`
23. `Sources/LakeOfFireFiles/Files/ReaderFileURLSchemeHandler.swift`
24. `Sources/LakeOfFireContent/Files/ReaderEBookPackageSnapshot.swift`
25. `Sources/LakeOfFireReader/Reader/Books/EPubMetadataDocument.swift`
26. `Sources/LakeOfFireContent/Files/ReaderEBookLocalAvailability.swift`
27. `Sources/LakeOfFireContent/Files/ReaderEBookInitialRestorePolicy.swift`
28. `Sources/LakeOfFireReader/Reader/Books/Document+Ebooks.swift`
29. `Sources/LakeOfFireContent/Files/ReaderFileStoragePaths.swift`
30. `Sources/LakeOfFireReader/Reader/Books/OPDS/OPDSCatalogsView.swift`
31. `Sources/LakeOfFireReader/Reader/Books/EPub.swift`
32. `Sources/LakeOfFireContent/Files/ReaderFileRefreshQueue.swift`
33. `Sources/LakeOfFireContent/Files/Archive+Data.swift`
34. `Sources/LakeOfFireOPDS/URLHelper.swift`
35. `Sources/LakeOfFireReader/Reader/Books/EbookHTMLResponseMetadata.swift`
36. `Sources/LakeOfFireContent/Files/ReaderEBookRenditionSelection.swift`
37. `Sources/LakeOfFireContent/Files/ReaderEBookServingSession.swift`
38. `Sources/LakeOfFireReader/Reader/Books/OPDS/OPDS Models.swift`
39. `Sources/LakeOfFireReader/Reader/Books/ReaderEBookInitialization.swift`
40. `Sources/LakeOfFireContent/Files/URL+ReaderFileURL.swift`
41. `Sources/LakeOfFireOPDS/OPDS1Parser.swift`
42. `Sources/LakeOfFireFiles/Files/ReaderFileDocumentLoader.swift`
43. `Sources/LakeOfFireContent/Files/ReaderFileManager.swift`
44. `Sources/LakeOfFireContent/Files/ContentPackageFile.swift`
45. `Sources/LakeOfFireReader/Reader/Books/EbookURLSchemeHandler.swift`
46. `Sources/LakeOfFireContent/Files/ReaderFileImportPresentation.swift`
47. `Sources/LakeOfFireFiles/Files/ReaderFileManagerSetupModifier.swift`

## Remaining unresolved work

Execute and independently review the new XML metadata regression source; full Archive+Data limits/cache/namespace comparison; every EbookURLSchemeHandler processing/sidecar/presentation route against #50/#53/#74; storage inventory captured-selection/Realm write admission and source-slot integration; all mixed test method bodies, auxiliary scripts/config and four design-document narratives. Existing book deletion branch tests must remain protected. Current source inventories are fully accounted, but these unresolved boundaries prevent a complete-audit claim.

Changes are intentionally unstaged and uncommitted for parent integration. No PR was created, pushed, merged or closed. Root pins were not advanced. The frozen worktree main HEAD remains the target SHA listed above.
