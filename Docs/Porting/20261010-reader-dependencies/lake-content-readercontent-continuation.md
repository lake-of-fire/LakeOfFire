# ReaderContent ownership continuation — 2026-10-11

Bounded READ-ONLY semantic pass: `ReaderContent.swift` cached/preloaded/load/completed-accessor ownership and durable snippet-title publication, direct caller edges and direct existing regression source. No repository edits/commits, builds/tests/benchmarks/native apps/generators. Only this task-root continuation report was written. No worker messaging. Broader Content/Library/resource paths remain open in the prior slice report.

## Frozen objects and evidence tiers

- Lake main target: `8985bf92b9504d53e00025e4054b3aa97f876e45`.
- Lake hotfix selected dependency: `036d4193078016db0becdf91b86dd34fb1d579e0`.
- Current isolated Lake candidate at pass start: `b66839466a38c7f6e18207910eacb6211ba5905f`. ReaderContent and direct main coordination/title tests are identical to frozen main (`git diff --quiet` status 0 for those three paths). Existing prior candidates are committed; no new source changes in this pass. Status at entry: only untracked `Docs/`, not touched. Candidate moved during pass to `55b7e55718430e3f2682feae6f8736d83b545f45`; the intervening commit changed Docs audit/report files only. Rechecked the three owner/test paths against frozen main: still identical (status 0). Final status clean.
- Caller evidence captured separately from frozen Lake: current committed upstream Reader root `3c10696d33c294e6657945d66353212ce4b76c43` selects ReaderCore `c4b86d15a42e8db174c95fac20b1561f50797a13`. Current committed hotfix Reader root `1da64556cb01276c26be393ce0ae09f79ee0de2a` selects Core `2fd72ecaa9e69e2cf867e4157c24d520a7d46dc5`. Caller reads used exact committed Core objects via `git show`/`git grep`, not dirty checkout content. These roots are a read-only current caller snapshot, not a newly audited entire root boundary.

Provenance, exact eligible hotfix lineage:

- `2f6e08e0bca0c4303b1b4dbc7ac16fd02e3e53b4` (2026-09-07), “Harden reader content authority”: target-URL title command and runtime rename regressions.
- `43db952704bacc9945eb6e5001e3ad9cef5d7ba1` (2026-10-06), “Retire displaced content loads and release failed retries”: producer-owned cleanup and fast-path retirement (`finishLoading(ifOwnedBy:)`).
- `c0e5e80091b5d0772dc39d9719562f36c23a2fc8` (2026-10-07), “Revalidate completed Reader content delivery ownership”: persistent `selectionID` and completed accessor/reuse/return-to-same-object regressions.

## Pending PR comparison

Every fetched upstream pending head has the exact main `ReaderContent.swift` blob `ba060b80f41112e3d481b276c5a8e8826fac46f6`. Therefore neither main-based nor EPUB-integration-based PRs close these owner gaps. Equality here proves absence of an owner modification; caller behavior was traced independently below.

- [#95](https://github.com/lake-of-fire/LakeOfFire/pull/95), `21c42ff0138c0b5b934956cbcccd107e5c577cf6`, base `main`: same main owner blob.
- [#74](https://github.com/lake-of-fire/LakeOfFire/pull/74), `ad19065bd567f09f64a7f321feb2087fd60701fa`, base `port/epub-serving-safety-integration-20260928`: same main owner blob.
- [#61](https://github.com/lake-of-fire/LakeOfFire/pull/61), `0dc1e429fc8e2d2b7e7f2a176fe2f72fabc7ab9e`, base `port/epub-serving-safety-integration-20260928`: same main owner blob.
- [#59](https://github.com/lake-of-fire/LakeOfFire/pull/59), `0dd0b07afac69c6d02512a7b02ff2acb27bf7bb0`, base `port/epub-serving-safety-integration-20260928`: same main owner blob.
- [#54](https://github.com/lake-of-fire/LakeOfFire/pull/54), `28c6911ada2221bc9a390de65f31b79bfba84bd4`, base `main`: same main owner blob.
- [#53](https://github.com/lake-of-fire/LakeOfFire/pull/53), `35e0a7e65ce63365a9923a92fac832ad087c549b`, base `main`: same main owner blob.
- [#51](https://github.com/lake-of-fire/LakeOfFire/pull/51), `547b1e88a836c8c4b53c24c98294700e9066a745`, base `main`: same main owner blob.
- [#50](https://github.com/lake-of-fire/LakeOfFire/pull/50), `0b91431f0fe04c45b24b08b427a5df66e87661b9`, base `main`: same main owner blob.
- [#48](https://github.com/lake-of-fire/LakeOfFire/pull/48), `2f3a63733583e179bddc8025a7320141fc1ddade`, base `main`: same main owner blob.
- [#41](https://github.com/lake-of-fire/LakeOfFire/pull/41), `af14b895d9d3e1a1fe8c3a00e52c158d6eae211e`, base `main`: same main owner blob.

Hotfix-only [#137](https://github.com/lake-of-fire/LakeOfFire/pull/137) `8b9d8381ce7561625452545b99260b29aaf81f37` has blob `a83e543b19edc47020c457af0f01d8f6fc799225`; [#113](https://github.com/lake-of-fire/LakeOfFire/pull/113) `9ef23abaecf93eb24dfbe55cbf02e9598f4f935f` has blob `aa7669bb09906e74df1e767dd353d54effdb538b`. Both base `v3-hotfix`, so neither is an upstream port disposition. Selected hotfix endpoint remains the final implementation oracle.

## Behavior classifications and concrete missing sequences

### P1: cached/preloaded selection retirement — genuinely missing

Main `Sources/LakeOfFireContent/Reader/ReaderContent.swift:202` `load(url:)`: same-URL in-flight coalescing at 233–245 is appropriate and retained. Existing-content fast path at 246–265 and `consumePreloadedContentIfMatching` fast path at 267–279 both return before cancellation/identity retirement at 288–290. Main `loadingRequestID` changes only when creating a new resolver task. Thus normal late-request ID checks cover uncached A→uncached B, but do not cover replacement by cached/preloaded B.

Concrete counterexample, production owner sequence:

1. A resolver enters and suspends; `loadingRequestID=A`, `loadingTask=A`.
2. Restore preloads B and `load(B)` consumes B; published `content/pageURL` become B but task/ID stay A.
3. Resolver A resumes (it need not honor cancellation, and no cancellation was requested). Main task guard still sees ID A and publishes A; pageURL remains B. `contentTitleSubject` emits A after B.
4. Cached existing B chosen while A remains suspended takes the same return-before-retire branch.

Hotfix `ReaderContent.swift:141` injected-resolver `load` keeps coalescing before retirement, but at 177–188 withdraws the preceding task slot, changes selection identity, cancels old work, and only then handles existing/preloaded fast paths. `selectionID` persists when resolver work is cleaned up. No-op reuse with no in-flight task returns before changing that identity, preserving legitimate completed readers. It also checks cancellation before state mutation (142).

Direct source-owned regressions: hotfix `ReaderContentLoadingOwnershipTests.swift:63` preload late A, `:88` late title publication, `:104` cached fast-path retirement, `:118` matching-display retirement, `:219` later return to old URL, `:281` preload does not replace already running same URL, `:299` unrelated preload retention, `:325` cancelled cached navigation, `:386` cancelled uncached navigation, `:460` section index preservation/reset. These use the real owner with a controlled asynchronous resolver; no user Realm needed. Source assertions, not observed execution results.

### P1: producer cleanup ordering and displaced completed accessors — genuinely missing

Main `load(url:)` cleanup is in the initiating caller’s defer (320–325), after awaiting `loadingTask.value`. A coalesced waiter can observe original failure and immediately retry while the initiating caller has not yet run cleanup; it rejoins the already-failed task instead of starting a fresh request. Existing main `ReaderContentLoadCoordinationTests.testFailedResolverDoesNotPoisonRetryForSameTarget` retries only after its initiating await throws, so it does not cover this interleaving.

Main `getContent():339` awaits `loadingTask?.value` and directly returns that value. A request ID checked inside the producer before publication does not validate a queued consumer after suspension. Sequence: accessor captured A task → A finishes/publishes → B preload or navigation replaces current selection → accessor resumes and returns old A. Reentrant `contentTitleSubject` subscriber replacement can produce the same result even without a second asynchronous resolver. Matching URLs or returning to the same object later do not restore authority to the displaced read.

Hotfix task’s own defer at `ReaderContent.swift:219` releases its owned loading slot before coalesced readers receive completion; cleanup at `:236` checks persistent selection ID. `getContent():249` captures selection ID before await and at `:259` requires both unchanged selection and exact published object identity. It returns nil for displaced successful reads while preserving the original thrown error. A current immediate read still returns displayed content; no-op reused selection keeps legitimate completed readers valid.

Direct tests: hotfix ownership suite `:201` pending accessor then preload, `:427` 32 coalesced failure waiters immediately retry, `:471` queued readers after successor publication, `:508` reentrant title replacement for different and same URLs, `:578` unchanged reuse, `:589` A→B→same-object A does not reopen retired read, `:603` normal cleanup still returns accepted content, `:624` original accessor failure survives replacement. The 32-waiter source stresses scheduling, not a proof of execution in this pass.

### P1: durable snippet title command and delayed target capture — genuinely missing

Main `ReaderContent.swift:353` `updateContentTitle(_:)` reads currently displayed content when the asynchronous task begins. It writes `content.title` and prefix state directly (368–369), then publishes chrome/title changes (370–371), and only afterward awaits `ReaderContentLoader.updateContent` (375). A managed/frozen Realm content object is mutated outside the owning write transaction; a non-managed source is visibly renamed before durable success. Storage failure is caught/logged at 388–389, so the caller receives no unsuccessful result. Direct pre-mutation can also make a subsequent same-object comparator see no change and skip explicit metadata refresh. These are source-proven ordering/ownership violations; this pass did not execute a crash or inject failure.

Hotfix `ReaderContent.swift:266` accepts explicit `targetURL`, returns `async throws -> Bool`, and awaits `ReaderContentLoader.updateSnippetTitle` before UI publication. The default chooses current content URL at invocation; explicit URL is needed for delayed caller intent. It re-resolves a managed reference only if the currently displayed URL still equals the target, then rechecks exact observed object identity after reference resolution before replacing/publishing. `ReaderContentLoader.swift:1396` guards snippet URL/nonempty title and computes the generated-prefix flag from each persisted representation’s current HTML inside `updateContent`; no-op mutations return false. Captured-storage overload `:1423` carries `SnippetStorage` and final permitsCommit admission through the stronger existing writer.

Concrete upstream caller bug: A’s rename sheet opens → navigate to B → sheet submits A’s intended new title → task calls `updateContentTitle` without captured target → method resolves B and renames B. Merely porting the default method’s commit ordering does not fix this caller. The debounced editable-title flow can similarly fire after content replacement.

Source oracle tests hotfix `ReaderSnippetTitleTests.swift:1036` managed durable rename and journal/no-op/empty, `:1079` frozen refresh after commit, `:1100` persisted HTML governs generated-prefix flags, `:1135` explicit old target after displayed content changes. `:941` captured rename/append after global configuration replacement tests the captured **loader** overload, not the default ReaderContent method; do not credit it as end-to-end UI account/storage fencing. None inject writer failure through the public ReaderContent rename method or demonstrate actual mounted delayed sheet submission.

## Actual caller and awaited-state trace

| Exact object/path/function | Classification and causal connection |
|---|---|
| Main Lake `Sources/LakeOfFireReader/Reader/ReaderViewModel.swift:234`, initializer assigning `ReaderContent.contentResolver` | Correctly connected production resolver → `ReaderViewModel.getContent(...)`, awaited by ReaderContent producer. Preserve this upstream resolver injection API; hotfix directly calls Loader and introduces an instance overload, which should not overwrite upstream integration. |
| Main Lake `Sources/LakeOfFireReader/Reader/ReaderWebView.swift:129`, `handleNavigationCommitted` | Awaits `readerContent.load(state.pageURL)` then invokes reader/reader-mode/media consumers. Early content read at 135 has no URL equality guard; media branch later checks URL at 149. Caller cancellation checks do not repair an uncancelled A producer surviving a preload/cached B selection. Owner fix needed. No source change proposed to this broader callback pipeline in this pass. |
| Main Lake `Sources/LakeOfFireReader/Reader/ReaderModeViewModel.swift:2685`, `resolveReaderModeRouteDecision` | Awaits `getContent()` at 2688 and 2729, uses returned content’s full-body flag/HTML to choose local render route. Displaced accessor can choose old-document HTML unless existing outer generation admission rejects it. Outer render lifecycle not audited here. |
| Same file `:2792`, `readerContentRenderSnapshot` | Awaits `getContent`, constructs URL/title/prefix snapshot from returned object. Snapshot coherence does not prove current selection admission; accessor fix owns this edge. |
| Core `c4b86d15` `Sources/ManabiReaderCoreReader/Reader/ReaderContainer.swift:2604`, restore navigation | Stored lookup is awaited, then content preloaded for stored URL and navigation dispatched. This establishes production reachability of ReaderContent’s preload path; cancellation of restore caller is not cancellation/retirement of the earlier ReaderContent producer. |
| Core `c4b86d15` `Sources/ManabiReaderCoreReader/Reader/SnippetAppendBar.swift:238`, `presentRename` | Reads current title to seed modal; closure captures only text and ReaderContent reference, creates Task and awaits nonthrowing update with no captured URL/configuration. Concrete delayed-target gap. |
| Core `c4b86d15` `Sources/ManabiReaderCoreReader/RootNavigation/Navigation/Tabs/Lookups/LookupsSnippetReaderView.swift:512`, debounced editable-title change | Task awaits update using whichever content is current, no captured snippet URL/storage or result/failure presentation. Needs caller-bound target with lifecycle/ordering admission. |

Hotfix Core `2fd72eca` restore callers at ReaderContainer 2420/2474 preload and 2558 await prepareForDisplay establish hotfix integration, but no `updateContentTitle` production call was found in its committed Sources. Upstream callsite adaptation must therefore be designed and tested explicitly; a same method name in Lake is not a complete UI port.

## Frozen-main reviewed path/test classifications (before tranche 1)

- `Sources/LakeOfFireContent/Reader/ReaderContent.swift`: **partially/incorrectly ported**, ordinary uncached request-ID guard exists; fast-path retirement, producer cleanup, persistent selection admission and durable explicit-target rename **genuinely missing**.
- `Sources/LakeOfFireContent/Reader/ReaderContentLoader.swift`: **partial owner adaptation required**, main `updateContent:534` writes/refreshes actor-owned loaded representations, but no `updateSnippetTitle` owner at frozen main. Hotfix target/metadata/captured-storage snippets prove intended contract; full storage helper port deliberately outside this finite pass.
- `ReaderViewModel.swift`, `ReaderWebView.swift`, selected ReaderModeViewModel functions, and three Core caller paths above: **caller reachability reviewed**, ownership risk/open boundaries stated; no claim these full files are audited.
- Main `Tests/LakeOfFireTests/ReaderContentLoadCoordinationTests.swift`: four methods reviewed. Uncached replacement and sequential retry **narrowly covered by source tests**; navigation-token ordering and blank suppression intentionally retained. None tests preload/cached retirement, queued completed accessor or producer cleanup retry race. Resolver seam statically available.
- Hotfix `Tests/LakeOfFireTests/ReaderContentLoadingOwnershipTests.swift`: all 31 method declarations inventoried and real-owner resolver/gate plumbing inspected; key counterexamples above read in full. Source fixture uses unmanaged HistoryRecords. It is absent frozen main and all upstream PR owner ports; **genuinely missing regression families**. The portable build switch is test plumbing, not a reason to restore a validation generator; use owning package runtime tests.
- Main/hotfix `Tests/LakeOfFireTests/ReaderSnippetTitleTests.swift`: main four HTML/URL/bookmark tests reviewed, no ReaderContent rename execution; hotfix five direct rename/captured-loader methods above reviewed, **missing runtime regressions upstream**. Full remaining snippet suite not closed.
- Hotfix `Tests/LakeOfFireTests/ReaderContentLoadingStorageTests.swift`: inspected selected storage-admission test declarations and existing actor/gate fixtures for boundary distinction; **broader storage test suite explicitly not audited/closed**. It does not replace displayed selection/public title-owner regressions.
- `Package.swift` LakeOfFireTests ownership: source glob includes ordinary tests; no compile/discovery/platform execution claimed. Preserve package membership and existing Swift 6 API shape; no generated project or portable harness restoration.

## Finite next implementation boundary

Implement two separable focused tranches, each retaining upstream public architecture:

1. ReaderContent selection owner only + real owner runtime tests. Preserve static resolver integration and navigation-task tokens. Keep same-target coalescing and ignored blank navigation. Check caller cancellation before any state displacement. Distinguish persistent selection identity from temporary loading task; retire old selection before cached/preloaded paths; producer-owned completion cleans up before retry waiters awaken; accessor validates persistent selection and exact published object after await. Regressions should include preload/cached replacement, cancelled uncached/cached requests, same-URL coalescing, errors/instant retry, current no-op reuse, A→B→same-object A and reentrant subscriber replacement. Do not replace original failures with nil or cancel the shared resolver because one coalesced waiter stops waiting.
2. Durable title command + its ReaderCore caller tuple. Capture snippet URL and storage/admission at modal open/edit intent, pass explicit target to asynchronous command, calculate prefix flag from persisted HTML, mutate/refresh on RealmBackgroundActor and await commit before UI publication. Public result must surface durable failure/no-op. After await, refresh only when displayed target/object still admitted. Add failed write, frozen/managed content, no-op/journal, concurrent HTML change, delayed A modal after B selection, debounced field replacement and storage/account replacement cases. Captured-storage loader contract should be reused/adapted, not a second generic writer. This crosses Lake + the two exact Core caller paths; no Lake-only API change may be claimed fully integrated.

## Additional reproducible shuffled exploration

Seed `20261011`; `random.Random(seed).shuffle` over the ordered finite list below. This supplementary pass revisited producer cleanup, route consumer, title callsites and completed-read source fixtures. No claim that random ordering closes unreviewed paths.

1. ReaderContentLoadCoordinationTests existing source
2. ReaderContentLoadingOwnershipTests hotfix source
3. ReaderContent.getContent completed-read admission
4. ReaderWebView navigation await consumer
5. ReaderCore SnippetAppendBar delayed rename
6. ReaderContent.load cached/preloaded retirement
7. ReaderContent.updateContentTitle durable publication
8. ReaderCore LookupsSnippetReaderView debounced title
9. ReaderCore ReaderContainer preload restore
10. ReaderSnippetTitleTests direct rename source
11. ReaderModeViewModel route/render snapshot consumers

## Read-only pass closure limits (before tranche 1)

Source audit complete for the listed bounded behavior edges; implementation remains missing. No source edits or commits, builds/tests/generators ran. Frozen main owner remained unchanged in current candidate. Findings do not close broader ReaderContentLoader storage lifecycle, all reader render/publication stages, full snippet tests, mounted iOS/macOS behavior or the original 60-path slice. No published/root-integrated/runtime-verified claim.


## Implemented focused tranche 1 — selection owner (2026-10-11)

The frozen-main classifications above describe the audited baseline. This tranche changes only `Sources/LakeOfFireContent/Reader/ReaderContent.swift` and adds `Tests/LakeOfFireTests/ReaderContentSelectionOwnershipTests.swift`; this task-root report is the only report updated by this worker. No durable title API, ReaderContentLoader storage helper, Core caller, navigation-task token, or public resolver signature changed.

| Candidate function/field | Exact behavior now authored | Provenance/classification |
| --- | --- | --- |
| `ReaderContent.swift:52`, `selectionID` | Persistent private selection identity survives producer cleanup and queued delivery; replaces temporary `loadingRequestID`. | Focused adaptation of frozen selected hotfix `c0e5e80091b5d0772dc39d9719562f36c23a2fc8`; **authored, runtime unverified**. |
| `ReaderContent.swift:203`, `load(url:)` entry and fast paths | Cancellation checked before state displacement; ignored blank paths and live same-target coalescing retained. Accepted same-display reuse without pending work keeps identity. All other selections rotate identity, clear owned loading slot and cancel displaced task before cached/preloaded publication. | Focused adaptation of `43db952704bacc9945eb6e5001e3ad9cef5d7ba1` and `c0e5e800`; **authored, runtime unverified**. |
| `ReaderContent.swift:309`, resolver producer; `:347`, `finishLoading(ifOwnedBy:)` | Producer defer clears only its selection's loading task/URL before its value/error wakes waiters. Initiator defer remains as guarded cleanup. Success/error of displaced producer cannot clear a successor slot. Static resolver invocation `(url, true, "ReaderContent.load")`, home fallback and resolved URL check retained. | Frozen selected hotfix producer-cleanup contract; **authored, runtime unverified**. |
| `ReaderContent.swift:358`, `getContent()` | An awaited value is returned only if captured selection identity still matches and exact object is current publication. Original error propagates. Ordinary immediate current content remains available. No-op current reuse remains admitted; A→B→same-object A stays retired. | Frozen selected hotfix completed-accessor contract; **authored, runtime unverified**. |
| `ReaderContent.swift:235`, coalescing guard | Does not join an already-cancelled producer task. | Separately inspected remote-tail `13f6fc39be9617ed4e7639a7573c6abbf82ac228`, ancestor of final remote hotfix `00dcfa75f3f65337450089b2df15ed2be779bb79`. Tail's `selectionLifetime`, handoff/intent withdrawal and retry admission API do not exist at main: this guard is a narrow applicable protection, **not a claim that full tail cancellation semantics were ported**. Reader roots still select `036d4193`, so frozen inventory/provenance remains distinct. |

### Authored real-owner runtime regression source

`ReaderContentSelectionOwnershipTests.swift` uses production ReaderContent, production Tasks and Combine publication, unmanaged HistoryRecords and an awaited expectation gate. The helper injects only through main's existing static resolver, asserts its production visit/source arguments and restores the previous resolver per test. No new public testing overload, generated project, portable harness or fake owner was added. Existing four `ReaderContentLoadCoordinationTests` remain unchanged.

- `:62` preloaded B displaces/cancels late A; verifies B content/page/title/accessor and no resolver invocation for B.
- `:89`, `:105` cached B and already-matching B display displace unrelated A.
- `:120` live same-URL resolver remains coalesced when preload exists.
- `:140`, `:163` already-cancelled preloaded and uncached requests preserve active producer, page and unused preload.
- `:185` 32 coalesced error waiters preserve original failure and immediately retry; one fresh successful producer must resolve, including before initiating consumer cleanup resumes.
- `:220` synchronous title publication subscriber replaces the object at both same and different URL; pending accessor returns neither displaced A nor adopted B.
- `:287` completed delivery across no-op current reuse. The scheduler-dependent A→B→same-object A case was removed during independent review because it could pass with no qualifying samples.
- `:300` ordinary pending accessor still returns accepted publication after producer cleanup.
- `:323` pending accessor retains original producer failure after a preloaded successor replaces it.

There are 11 authored regression methods. Completed-delivery sampling (`:252`) remains only as a no-op reuse acceptance fixture: every sample must return content, so it has no filtered rejection assertion. The transition-status filtering and Task priority hints were also removed. The A→B→same-object A rejection test was removed because scheduler choice could produce no late-delivery samples and pass vacuously. Deterministic same-object ABA completed-delivery runtime coverage remains missing; no timing assumptions, new production hooks or scheduler seam were added. The persistent identity guard remains authored based on selected-pin source evidence, but this exact rejection sequence has no deterministic runtime oracle in this tranche. Runtime/compilation/platform execution is entirely unverified, as instructed. The static resolver is global; concurrent independently configured ReaderContent test suites require their existing runner isolation policy.

### Remaining boundary and verification

Durable title command, persisted-prefix/no-op/write-failure semantics and exact ReaderCore rename/debounce caller target tuple remain **missing and parent-owned**, including provenance `2f6e08e0bca0c4303b1b4dbc7ac16fd02e3e53b4`. No Lake-only title API was introduced. Broader loader storage/account lifetime, remote-tail handoff withdrawal/retry semantics, render-consumer admission, UI selection projection, mounted reader behavior and unreviewed original audit paths remain open. Mid-flight cancellation of an initiating outer `load` task does not introduce a new public cancellation-lifetime contract here; one waiter cancelling does not cancel the shared resolver.

`git diff --check` completed successfully after source/test authoring. No tests, builds, generators, stage, commit or push executed by this worker. New test file is ordinary owning package source; package discovery/compilation is not claimed. No additional shuffled exploration performed during implementation: previously recorded seed/order above remains the supplementary read-only pass record.
