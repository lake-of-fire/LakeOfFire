# Porting composition: catalog consumers, book imports and owned EPUB serving

## Exact inputs

This increment extends existing main-targeting PR #50 rather than opening a competing integration branch.

| Input | Revision |
| --- | --- |
| Previous #50: identity plus EPUB safety | 3eb2368dd155343cf11fc2de4ddeb7717802eaa0 |
| Current #41: safety plus downloaded-book import/retry | 23a1a5ce9039ebc63d0c11425863fb1797502cae |
| Current #48: OPDS plus owned catalog consumers | 2f3a63733583e179bddc8025a7320141fc1ddade |
| Main base | ac5894d936a15b9d305dafdaeac7afac5a0366dd |

The composition commit retains all three input commits as parents. #37's existing history remains through the first parent. Source PR branches and main/v3-hotfix are not updated or merged to main. A later source-head change requires another explicit integration review.

## What is composed

The previous #50 contained #41 only through 4c53c0f9 and no #48 catalog port. It therefore omitted the later downloaded-book import outcome/retry gates and still used main's older OPDS implementation.

Bring forward all ten changed paths between #41's earlier and current heads, including the exact list/grid adapters, import state, row-task owner, tests, package runner and ownership workflow. Bring forward all 29 #48 changed paths, retaining complete parser/transport/async code, request ownership, bounded traversal, model extraction, detail view, tests and native qualification workflow.

**BookLibraryView.swift is the single shared production path requiring reconciliation.** Keep #50's shared readerContentFileImporter and isActive-gated binding, rather than restoring #48's historical raw fileImporter and print-only errors. Keep #48's awaited Editor's Picks refresh and BookCatalogLoading delegation. Publication exists exactly once in the new same-module Foundation file. The resulting BookLibrary blob is afc69797bbbdbd97be1d5f0a20731fe0698eefcb. All other copied paths retain their input blobs exactly.

The previous #50's serving/fingerprint limits, directory-slash accounting, immutable snapshot/capability ownership, selected rendition, initialization receipts, native loader, restore-before-saving checks and all JavaScript files remain byte-identical. No generic resource limits, schemas, Realm operations, historical identity keys, root pins or production Package.swift change.

## Integrity and executed local evidence

The previous integration artifact was downloaded and its SHA-256 verified (1047d75a3c5c9e2a2a1d562c0f9ffe2b1048e283cae83c0776fdbcf09233b09d). Its 541 retained source/test/manifest files matched the tested Git manifest. #41/#48 retained input files also matched their manifests. The entire previous root tree was reconstructed as 707dbd161c522892bc16776c5680fde27b2fde2e; the exact combined tree before this new document is 16b6bc1b7806df629a2c7884c91fb4ff51a6dbd0, matching GitHub's created tree.

Executed on Linux x86_64 with Swift 6.2.1, explicit Swift 6 mode and warnings as errors where used by the retained runners:

| Suite | Result |
| --- | --- |
| Entire JavaScript suite, Node 22.16.0 | 338 passed; zero failures/cancellations/skips |
| Complete OPDS target | 102 Debug and 102 Release passed; zero failures/skips |
| Actual catalog loader/refresh/model components | 27 Debug and 27 Release passed; zero failures/skips |
| BookDownloadOperation | 15 Debug and 15 Release passed; zero failures/skips |

These are retained tests, not newly authored cases, and repeated builds do not add unique cases. The 15 owner cases overlap the native package runner. The catalog and download components are separate selected graphs, not a combined full LakeOfFireReader build.

Local staging initially lacked unchanged OPDS sample/support files; the first build failed before tests. Restoring their exact manifest-matched bytes repaired staging, not production. Combined runner invocations then completed Debug but exceeded the execution deadline during optimized compilation. Separate Release invocations completed successfully; the catalog Release rerun used the same retained workspace and two build jobs. Interrupted invocations are not counted as successful complete runs. BookLibrary's merged adapter passes Swift frontend parsing only.

## Qualification at this new composition

Run the retained JavaScript, package/import, fingerprint/serving, entry-path, initialization, message, OPDS, catalog and download-owner workflows against this exact new head. Their previous per-PR passes are historical evidence, not this composition's native outcome. The copied OPDS workflow includes the actual detail-view macOS compilation and selected iOS 15 simulator module typecheck.

Keep draft pending native result inspection, full BookLibrary/list/grid/catalog-management/Realm/WebView builds, real catalog acquisition/import/retry/dismissal and EPUB open/restore/close, source/test discovery in the root generated graph, compatible Common/Core/WebView selections, persisted migrations and signed two-client validation. This unifies the Lake runtime candidate; it does not select or qualify the application's complete dependency tuple.

No source PR is closed, merged to main or rewritten. No root gitlink, schema, historical key, original book, shared downloader policy, signing, rollout flag or CloudKit setting changes.
