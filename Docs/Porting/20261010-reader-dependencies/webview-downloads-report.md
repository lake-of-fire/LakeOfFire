# SwiftUIWebView and SwiftUIDownloads dependency audit — 2026-10-10

Owned scope: only `swiftui-webview` and `SwiftUIDownloads`, inclusive dated lineage 2025-10-10–2026-10-10 frozen in task-root `inventory.json`. No source edits, commits, pushes, builds, tests, benchmarks, generators, native app launches, installs, or CI dispatch. Tests **not run by request**. Read reconciliation skill, audit workflow and observed-failure-patterns; root AGENTS applies, neither assigned worktree contains a further AGENTS file.

## Exact evidence boundary

| Repository | Selected hotfix pin | Fresh fetched main target | Pending upstream PR |
| --- | --- | --- | --- |
| swiftui-webview | `da0ec9394a3a89734768768ad7b8cb6082ac9d80` | `da0ec9394a3a89734768768ad7b8cb6082ac9d80` | [#23](https://github.com/lake-of-fire/swiftui-webview/pull/23), head `c13e5da5b343f56631234d6d9957655dd91d5d04`, base main `da0ec9394a3a89734768768ad7b8cb6082ac9d80` |
| SwiftUIDownloads | `fc5c35173e440309c89828a673bcaa485248eaf9` | `18077d0cd9506c40dccafeb754f58b6599987337` | none in frozen inventory |

WebView: 239 eligible dated commits, 50 dated paths; selected hotfix and main are literally the same commit. All 50 paths equal. Downloads: 114 eligible dated commits, 47 dated paths; 46 equal paths, one differing test. All 18 dated Downloads production paths equal. Equality is endpoint transfer evidence; behavior/caller inspection below does not turn it into an assembled application or release claim.

Original upstream Reader root observed `3c10696d33c294e6657945d66353212ce4b76c43` selects Lake `808dbaf3721af9903aa4cba827b791c17581e4e3`, Core `c4b86d15a42e8db174c95fac20b1561f50797a13`, WebView `7bc82bdac062feea4213c59551ce939d0bac2061`, Downloads `bfb5383774e70082eedeee3064d1fb8868301713`. Thus newer dependency-main behavior is not root-pinned there. Core checkout has extensive dirty work; initial caller searches saw that working tree, then conclusions were re-proved with committed Core blobs at `c4b86d15...`. Dirty caller content is not credited. Lake caller evidence uses task worktree fresh main, exact SHA recorded in inventory. No original checkout was modified.

## Findings and disposition

1. **Correctly ported to dependency main:** WebView native binding/document ownership, receipt capture/order, JavaScript dispatch/error/coercion, frame identity retirement, snapshot fencing, load progress publication, pool capacity/content affinity, trusted-action lifetime and iOS scroll ownership all have identical selected hotfix/main owners. Key provenance includes `d8e118329e06697f578234ae180606243d720d64` (reserve receipt before provider reentry), `58ace746c216ee96a049f8c0239f6c60190fd9c0` (capture binding), `b2e2b303da364dd5ae5b3deeb098087d5813fcbf` (MainActor dispatch), `768e7a4b65a54daa73036eb44e6cd9ced8f2a0a3` (macOS pooled script preservation), `30f1589c334b491cb7eb6fa749481558e46aff11` (dispatch continuation ownership), `58dfd82d638db94df20fd5b73d32de9f91e005ab` (invalid frame retirement) and `5e604c2a80f38e21073d6a670ee497e201c944d2` (progress generations). No fresh missing forward port found in this pinned slice.

2. **Correctly ported / stronger upstream test:** Downloads has identical production implementations for operation identity, compatible replay/conflict rejection, ownership completion, staged verified replacement, metadata persistence, retries/cancellation, stale import callbacks and orphan protection. Final hotfix provenance `fc5c351...` explicitly replaces direct native delegation with `DownloadTaskDelegate` and releases the retained owner at the sole terminal publication rather than assigning `downloadTask.delegate = nil`. Main test `URLResourceDownloadDeliveryIntegrationTests.testCancellationAfterDelegateInstallationSurvivesRepeatedResumeAndLateFile` retains the actual installed proxy before cancellation, drops fixture/subscription, awaits weak-wrapper release while native task/proxy remain alive, invokes actual late proxy completion/file callbacks, and verifies exactly one terminal result and unchanged destination/late file. Hotfix's older `XCTAssertNil(fixture.task.downloadTask.delegate)` contradicts that retained-proxy contract. Main's test strengthening provenance `3a1e01eb3eb4ae2b4ba824d65d1a0fc42ccc040c` and `f4d741ec9612d90f26350224792b7780e2dd8445`; do not overwrite it with hotfix test. No additional regression authored because main already owns the meaningful runtime regression.

3. **Pending upstream implementation, not selected hotfix residue:** PR #23 captures `nativeDocumentURL`, strict CFBoolean restoration hint, and native `isMainFrame` before provider/scheduler deferral; snapshots handler configuration so required-action/cancellation policies remain receipt-owned; provides handler-scoped receipt providers with collision rejection; introduces `WebViewURLTransitionIntent` and sequencer with canonical-fragment policy, permanent ABA withdrawal, exact-once observers delivered outside locks; fences reentrant Binding setter / URL callback publication. Existing main has global-only providers and deferred paths consulting mutable handler configuration; these are addressed in this pending PR, so no duplicate implementation here. Source tests in PR cover provider isolation/composition collisions, ordinary/broker restoration, child identity, string/numeric false hints, native URL capture, baseline/fragment classification, rapid return, forged location hints, detach and setter reentry. The two PR-added workflows are execution infrastructure, not runtime evidence for this pass. Its body contains historical results; none was promoted to current-source execution here.

4. **Unresolved shared integration limitation:** `SwiftUIWebView.swift`, `webView(_:decidePolicyFor:preferences:)` returns a nonnil `onNavigationAction` result (including explicit `.allow`) around line 5465 before default `updateUserScripts` around 5487. This same behavior exists in selected hotfix/main and PR #23 does not alter it. Re-proves the 2026-09-29 bounded selected WebView row in upstream `specs/HOTFIX-PORT.md`: actual pooled A→B navigation with differing domain-restricted script sets plus explicit `.allow` needs a mounted oracle. The inspected Core/Jmdict callback returning `.allow` has no proven affected domain-restricted product script configuration; DEBUG OCR transform supplies nil/cancel. Therefore no claim of reproduced product failure and no speculative port. This pre-existing row remains open.

5. **Unresolved application integration:** committed Core `c4b86d15...` has no `WebViewMessageReceiptCapture`, `receiptEvidenceProviders`, or `urlTransitionIntent` production use. Its `ManabiReader.handleNewURL(state:)` updates content-stat/cache-warming state; Lake's `ReaderWebView.onURLChanged` awaits internal URL handling via cancellable `NavigationTaskManager`, then calls Core's callback. Presence of PR #23 APIs does not establish consumer-side visit/undo/persistence policy. Parent must distinguish dependency-main, pending PR and root pin gates.

## Deterministic production review

All paths below are under the repository's `Sources/<module>/`. Status **correctly ported** means selected hotfix production is present identically at fresh dependency main; shared limitations explicitly remain above. Broad same-file older unrelated code is outside this finite forward-port audit.

| Repository / file | Inspected behavior and downstream use | Status |
| --- | --- | --- |
| WebView / LoadingProgressPublicationState.swift | generation resolution, clamp/nonfinite handling, clear invalidation; coordinator `updateLoadingProgress` resolves deferred generation | correctly ported |
| WebView / SwiftUIWebView.swift | document callback capture/activation/invalidation; receipt before providers; TaskLocal evidence transport; script binding and commit fence; evaluation/retry/frame retirement; optional/strict aggregate current-owner checks; snapshot bounds/binding/cancellation; navigation/load disposition, matching scripts, URL/loading publication; Lake ReaderWebView mounts it | correctly ported; shared explicit-allow limitation and PR-specific differences recorded |
| WebView / WKWebView+JavaScriptEvaluation.swift | MainActor `__callAsyncJavaScript` adapter preserves arguments/frame/world/throwing semantics; installed coordinator dispatch uses it | correctly ported |
| WebView / WebViewCoordinator+UIScrollViewDelegate.swift | exact navigator.scrollView guard, offset/direction/end detection, content-size/bounds/inset observers, equal-end suppression; Reader's scroll chrome uses callback | correctly ported |
| WebView / WebViewJavaScriptBindingCommitFence.swift | locked permanent revocation; caller changes/clear/document invalidation invalidate captured fences | correctly ported |
| WebView / WebViewMessageReceiptEvidence.swift | immutable binding sampled before app providers; sorted snapshot; TaskLocal value retains original receipt across deferral | correctly ported; PR adds scoped providers/native fields |
| WebView / WebViewPool.swift | weak known navigation receipts, exact pending finish/failure, reset stale ownership, retained+leased count, current checkout factory, duplicate enqueue, invalidate teardown, content-aware dequeue | correctly ported |
| WebView / WebViewTrustedUserAction+SemanticEquality.swift | action/scope/source equality excludes timestamp; timestamp still limits admission lifetime | correctly ported |
| WebView / WebViewTrustedUserAction.swift | per document/frame/action admission, original event lifetime and skew, one-shot consumption, native batch revocation, bounded scope/action/envelope, isolated-world broker | correctly ported |
| Downloads / BrotliFileDecompressor.swift | bounded modern read/write with cancellation and read-error propagation; legacy chunked input plus atomic output | correctly ported |
| Downloads / Data+Compression.swift | invalid page size/unsupported algorithm typed errors; compression/decompression filter entrypoints | correctly ported |
| Downloads / Download Views.swift | progress failure/install/import UI, unknown-length status, operation taskDescription selection, logical cancellation, readable-artifact check excludes failed retained diagnostic payload | correctly ported |
| Downloads / DownloadController.swift | source+destination key; execution configuration conflict; join enclosing work completion; replay observation; retry transfer/backoff/import ownership; staged decompression/hash and revalidation after importer; receipt/metadata commit before success; save-failure retry; orphan live-owner snapshot; observer retirement | correctly ported |
| Downloads / DownloadFileDelivery.swift | awaiting→delivering→terminal reservation, lock-free filesystem work/publication, prior destination preserved on rejected response/cancellation, single winner, missing-file terminal failure | correctly ported |
| Downloads / DownloadHTTPResponse.swift | missing/malformed HTTP response rejected, 206/content-range/multipart range rejected for whole GET, bounded finite Retry-After, unknown progress total | correctly ported |
| Downloads / DownloadMetadataCache.swift | namespace+source+destination identity; initial/save task registration under lock; dirty-field merge/revision retry including mutations during failure; waitForPendingSaves observes latest owner/error | correctly ported |
| Downloads / DownloadOrphanCleanup.swift | synchronous selected-root sweep, entry versus target identity, protected retained directories/alias ancestors, unlink only files/symlinks, rmdir only empty directories, cancellation/Realm sidecars | correctly ported |
| Downloads / DownloadProgressMetrics.swift | known total excludes unknown -1 / 0-with-bytes; status formats unknown totals and nonnegative throughput | correctly ported |
| Downloads / DownloadReplayObservation.swift | MainActor observe-after-change and final copy; stop invalidates queued observation copies, replay does not own producer | correctly ported |
| Downloads / DownloadStagingPaths.swift | bounded operation names; exact owner/destination namespace; alias-safe entry comparison, protect active entries, never follow leaf symlink, legacy names scoped to destination | correctly ported |
| Downloads / DownloadWorkCompletion.swift | producer completion distinct from UI; cancellation unregisters only waiter, registration cannot lose cancellation, continuation delivery outside lock | correctly ported |
| Downloads / Downloadable+Staging.swift | SHA256 operation-key ownership feeds transfer/expanded staging phase paths and orphan consumer | correctly ported |
| Downloads / DownloadableMetadataStore.swift | Codable receipt source/destination/digest/file metadata, destination-scoped persisted validator keys, nil clears old validator, store namespace | correctly ported |
| Downloads / GlassBackgroundEffectCompat.swift | availability branches preserve iOS15/macOS15 fallback; .never self | correctly ported |
| Downloads / ImportableDownloadable.swift | import callback generation ends on completion/cancel; execution signature includes normalized import identity/retention/options | correctly ported |
| Downloads / TarArchiveExtractor.swift | streamed 512-byte header + exact-copy/skip, path normalization rejects parent traversal/absolute path, unsupported type skips payload | correctly ported |
| Downloads / URLResourceDownloadTask.swift | repeated resume fenced; cancellation before/after delegate activation; session/task identity; terminal delivery admission; active owner lease releases while installed proxy forwards weakly | correctly ported |

Caller chains inspected read-only: Lake `BookLibraryView`, `BookGridCell`/`Book Views.swift` → `DownloadController.ensureDownloaded` → `ReaderFileManager.ensureImported`; Lake configured OPML downloads → finishedDownloads observer → importOPML; Core dictionary `YomitanDictionaryManagerView` ImportableDownloadable handler/isImported/configuration at committed pin; Core LookupsTab required/optional `ensureDownloaded` and unfinished-import UI. Lake BookGridCell's pending #50 `importIdentity` work is outside this ownership and unchanged. Existing package manifests link SwiftUIWebView/SwiftUIDownloads to Lake content/reader products; Reader Tuist manifest declares both local dependencies. Manifest linkage plus callers establishes source reachability, not actual native target execution.

## Recursive Brave/dependency discovery

Read `git ls-tree -r` for every frozen dated commit plus selected pin/main/PR head: 240 distinct WebView trees and 115 Downloads trees. Neither has `.gitmodules` entries or mode-160000 gitlinks. `git log --all -- .gitmodules` also has no history in either. Therefore no actually referenced nested Brave checkout to recurse into from these assigned repos.

WebView `Sources/SwiftUIWebView/URL+Extensions.swift` contains copied-source attribution to Brave `brave-ios` commit `77626701b8829d3696e057ccb3c39f7bd268eaec` and MPL 2.0 notice. Its `normalizedHost`/`domainURL` are used by domain-scoped user-script filtering. Preserve attribution; this is retained derived source, not Brave-repository checkout/link reachability. This file is not one of the nine dated source paths and was inspected specifically for dependency discovery.

## Reproducible shuffled correction pass

After deterministic behavior/caller review, re-read source seams in `random.Random(20261010).shuffle(sorted inventory dated source paths)` order (inventory's `dated_paths` are lexically sorted). No second-pass new missing forward port found. Two missing textual seam names in the initial excerpt reader were corrected with explicit manual excerpts (`Download Views.refreshDownloadable`, `DownloadMetadataCache.savePendingChanges`); those files were not skipped.

WebView order: WebViewPool; WebViewTrustedUserAction+SemanticEquality; SwiftUIWebView (evaluateBoundJavaScript continuation/retirement); WebViewJavaScriptBindingCommitFence; WKWebView+JavaScriptEvaluation; LoadingProgressPublicationState; WebViewTrustedUserAction (prune/native admission); WebViewCoordinator+UIScrollViewDelegate; WebViewMessageReceiptEvidence.

Downloads order: Download Views; BrotliFileDecompressor; TarArchiveExtractor; DownloadController (metadata acknowledgement/failure); DownloadStagingPaths; ImportableDownloadable; DownloadProgressMetrics; Downloadable+Staging; DownloadReplayObservation; GlassBackgroundEffectCompat; DownloadMetadataCache; DownloadHTTPResponse; DownloadFileDelivery; DownloadableMetadataStore; URLResourceDownloadTask; Data+Compression; DownloadOrphanCleanup; DownloadWorkCompletion.

## Test/config/documentation accounting and remaining gates

The following appendix accounts **every** dated path separately. Equal runtime test blobs necessarily preserve method bodies and test membership declarations between selected hotfix/main; runtime test source was mapped to reviewed families, but no compilation, test discovery, execution, native platform coverage or historical hosted result is credited. No source-string assertions authored. Portable scripts retained as equal existing evidence, never executed or transplanted. Generated project/workspace entries, workflows and historical closeout documentation are equal at WebView selected endpoints; they are bookkeeping/config evidence, not extra missing product ports. Existing package test targets declare their corresponding test directories. iOS-only scroll tests and macOS-only cold-script tests require distinct native execution; unchanged source does not prove both platforms ran.

No unaccounted eligible endpoint path remains. Remaining work is application compatible pins/consumer visit policy, the shared pooled explicit-allow runtime oracle, current-source native execution (deliberately forbidden here), and any newer unpinned checkout lineage. Original hotfix checkout WebView `76b09b96de380760d5b5bca41a5d6c893527ae31` differs from selected `da0ec939...` and is dirty in generated project: this audit does not silently substitute that state for the frozen pin. PR #23 is compared independently. Whole-tree historical intermediate semantics unrelated to selected dated forward-port behavior are not globally certified.

## Complete dated-path ledger

### swiftui-webview

| Path | Category | Endpoint disposition |
| --- | --- | --- |
| `.github/workflows/document-epoch-review.yml` | configuration/generated | equal; no port required |
| `.github/workflows/native-receipt-binding.yml` | configuration/generated | equal; no port required |
| `.github/workflows/native-receipt-stage.yml` | configuration/generated | equal; no port required |
| `.github/workflows/pr-review-source-export.yml` | configuration/generated | equal; no port required |
| `.github/workflows/receipt-boundary.yml` | configuration/generated | equal; no port required |
| `.gitignore` | configuration/generated | equal; no port required |
| `Documentation/undo-closeout-20260920/session-3.md` | historical docs/dev harness | equal; no port required |
| `Package.resolved` | configuration/generated | equal; no port required |
| `Package.swift` | configuration/generated | equal; no port required |
| `Sources/SwiftUIWebView/LoadingProgressPublicationState.swift` | production | equal; correctly ported |
| `Sources/SwiftUIWebView/SwiftUIWebView.swift` | production | equal; correctly ported |
| `Sources/SwiftUIWebView/WKWebView+JavaScriptEvaluation.swift` | production | equal; correctly ported |
| `Sources/SwiftUIWebView/WebViewCoordinator+UIScrollViewDelegate.swift` | production | equal; correctly ported |
| `Sources/SwiftUIWebView/WebViewJavaScriptBindingCommitFence.swift` | production | equal; correctly ported |
| `Sources/SwiftUIWebView/WebViewMessageReceiptEvidence.swift` | production | equal; correctly ported |
| `Sources/SwiftUIWebView/WebViewPool.swift` | production | equal; correctly ported |
| `Sources/SwiftUIWebView/WebViewTrustedUserAction+SemanticEquality.swift` | production | equal; correctly ported |
| `Sources/SwiftUIWebView/WebViewTrustedUserAction.swift` | production | equal; correctly ported |
| `SwiftUIWebView.xcodeproj/project.pbxproj` | configuration/generated | equal; no port required |
| `SwiftUIWebView.xcodeproj/project.xcworkspace/contents.xcworkspacedata` | configuration/generated | equal; no port required |
| `Tests/SwiftUIWebViewTests/LoadingProgressPublicationStateTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIWebViewTests/PendingRequestLoadDispositionTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIWebViewTests/WebViewAggregateFrameResultTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIWebViewTests/WebViewCoercionErrorTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIWebViewTests/WebViewDispatchFencingTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIWebViewTests/WebViewDocumentEpochEvaluationTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIWebViewTests/WebViewFrameIdentityTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIWebViewTests/WebViewInvalidFrameRetirementTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIWebViewTests/WebViewJavaScriptBindingCommitFenceTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIWebViewTests/WebViewMacColdUserScriptTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIWebViewTests/WebViewMainFrameAliasRetentionTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIWebViewTests/WebViewMessageReceiptEvidenceTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIWebViewTests/WebViewNativeLookupHitTestStoreTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIWebViewTests/WebViewPaginationConfigurationTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIWebViewTests/WebViewPoolTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIWebViewTests/WebViewReaderDocumentSummaryTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIWebViewTests/WebViewReaderLoadActivityTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIWebViewTests/WebViewReceiptDispatchTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIWebViewTests/WebViewReceiptDocumentBindingTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIWebViewTests/WebViewReceiptOwnershipTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIWebViewTests/WebViewReceiptSequenceTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIWebViewTests/WebViewScriptCallerTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIWebViewTests/WebViewScrollOwnershipTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIWebViewTests/WebViewSnapshotFencingTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIWebViewTests/WebViewSnapshotTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIWebViewTests/WebViewTrustedUserActionSemanticEqualityTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIWebViewTests/WebViewTrustedUserActionTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIWebViewTests/WebViewUserScriptSignatureTests.swift` | runtime regression source | equal; retained source, not run |
| `dev/receipt-evidence/README.md` | historical docs/dev harness | equal; no port required |
| `dev/receipt-evidence/ReceiptHarness.swift` | historical docs/dev harness | equal; no port required |

Counts: 10 configuration/generated, 3 historical docs/dev harness, 9 production, 28 runtime regression source.

### SwiftUIDownloads

| Path | Category | Endpoint disposition |
| --- | --- | --- |
| `.gitignore` | configuration/generated | equal; no port required |
| `Package.swift` | configuration/generated | equal; no port required |
| `Sources/SwiftUIDownloads/BrotliFileDecompressor.swift` | production | equal; correctly ported |
| `Sources/SwiftUIDownloads/Data+Compression.swift` | production | equal; correctly ported |
| `Sources/SwiftUIDownloads/Download Views.swift` | production | equal; correctly ported |
| `Sources/SwiftUIDownloads/DownloadController.swift` | production | equal; correctly ported |
| `Sources/SwiftUIDownloads/DownloadFileDelivery.swift` | production | equal; correctly ported |
| `Sources/SwiftUIDownloads/DownloadHTTPResponse.swift` | production | equal; correctly ported |
| `Sources/SwiftUIDownloads/DownloadMetadataCache.swift` | production | equal; correctly ported |
| `Sources/SwiftUIDownloads/DownloadOrphanCleanup.swift` | production | equal; correctly ported |
| `Sources/SwiftUIDownloads/DownloadProgressMetrics.swift` | production | equal; correctly ported |
| `Sources/SwiftUIDownloads/DownloadReplayObservation.swift` | production | equal; correctly ported |
| `Sources/SwiftUIDownloads/DownloadStagingPaths.swift` | production | equal; correctly ported |
| `Sources/SwiftUIDownloads/DownloadWorkCompletion.swift` | production | equal; correctly ported |
| `Sources/SwiftUIDownloads/Downloadable+Staging.swift` | production | equal; correctly ported |
| `Sources/SwiftUIDownloads/DownloadableMetadataStore.swift` | production | equal; correctly ported |
| `Sources/SwiftUIDownloads/GlassBackgroundEffectCompat.swift` | production | equal; correctly ported |
| `Sources/SwiftUIDownloads/ImportableDownloadable.swift` | production | equal; correctly ported |
| `Sources/SwiftUIDownloads/TarArchiveExtractor.swift` | production | equal; correctly ported |
| `Sources/SwiftUIDownloads/URLResourceDownloadTask.swift` | production | equal; correctly ported |
| `Tests/Portable/run_download_file_delivery.py` | portable evidence script | equal; no port required |
| `Tests/Portable/run_download_orphan_cleanup.py` | portable evidence script | equal; no port required |
| `Tests/Portable/run_download_staging.py` | portable evidence script | equal; no port required |
| `Tests/Portable/run_download_work_completion.py` | portable evidence script | equal; no port required |
| `Tests/SwiftUIDownloadsTests/BrotliFileDecompressorTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIDownloadsTests/DataCompressionTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIDownloadsTests/DownloadChecksumRecoveryTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIDownloadsTests/DownloadCompatibleReplayTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIDownloadsTests/DownloadDirectoryIsolationTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIDownloadsTests/DownloadFileDeliveryTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIDownloadsTests/DownloadMetadataCacheTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIDownloadsTests/DownloadMetadataTaskOwnershipTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIDownloadsTests/DownloadObserverLifecycleTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIDownloadsTests/DownloadOrphanCleanupTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIDownloadsTests/DownloadOrphanControllerTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIDownloadsTests/DownloadPartStagingIntegrationTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIDownloadsTests/DownloadProgressMetricsTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIDownloadsTests/DownloadRemoteLifecycleTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIDownloadsTests/DownloadRetryIntegrationTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIDownloadsTests/DownloadRetrySupportTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIDownloadsTests/DownloadStagingAliasTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIDownloadsTests/DownloadStagingPathsTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIDownloadsTests/DownloadWorkCompletionTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIDownloadsTests/SwiftUIDownloadsTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIDownloadsTests/URLResourceDownloadDeliveryIntegrationTests.swift` | runtime regression source | intentionally divergent; main stronger native-proxy lifetime oracle (finding 2) |
| `Tests/SwiftUIDownloadsTests/URLResourceDownloadTaskIdentityTests.swift` | runtime regression source | equal; retained source, not run |
| `Tests/SwiftUIDownloadsTests/URLResourceDownloadTaskTerminalTests.swift` | runtime regression source | equal; retained source, not run |

Counts: 2 configuration/generated, 18 production, 4 portable evidence script, 23 runtime regression source.

Lake caller inspected target: `8985bf92b9504d53e00025e4054b3aa97f876e45`; selected hotfix Lake `036d4193078016db0becdf91b86dd34fb1d579e0`. Reader root/Core/pin identities above are read-only committed evidence; no mixed dirty tree is claimed.

### Final owned-worktree state

- swiftui-webview: HEAD `da0ec9394a3a89734768768ad7b8cb6082ac9d80`, clean.
- SwiftUIDownloads: HEAD `18077d0cd9506c40dccafeb754f58b6599987337`, clean.

End-of-pass read-only Reader roots: upstream `3c10696d33c294e6657945d66353212ce4b76c43` (unchanged from initial observation), hotfix `1da64556cb01276c26be393ce0ae09f79ee0de2a`. Dependency origin/main refs still equal frozen targets and WebView audit/pr-23 still equals `c13e5da5...`. Hotfix root was sampled at handoff, not used to silently refresh frozen dependency inventory.
