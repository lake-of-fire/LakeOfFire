# ReaderContent selection ownership independent review

Status: source review finds no new defect in the bounded selection-only candidate. New regression source read after it became available; all findings below are source-only.

## Exact evidence and scope

Reviewed task18/LakeOfFire unstaged `Sources/LakeOfFireContent/Reader/ReaderContent.swift`, final-read blob `c2793b7ac93eec5eeaf09df0fca018e56c14ee36`, against frozen main `8985bf92b9504d53e00025e4054b3aa97f876e45`, selected hotfix `036d4193078016db0becdf91b86dd34fb1d579e0`, and captured remote `refs/remotes/audit/final-v3-hotfix` = `00dcfa75f3f65337450089b2df15ed2be779bb79`. Review began with current HEAD `55b7e55718430e3f2682feae6f8736d83b545f45`. The remote reference name ends in `final-v3-hotfix`; `00dcfa75` identifies its captured SHA.

Compared selected hotfix `ReaderContentLoadingOwnershipTests.swift` as behavioral evidence, current `ReaderContentLoadCoordinationTests.swift`, and production `ReaderViewModel.init` resolver installation. No source edits, commits, build, parsing/typechecking, tests, dependency resolution, or native application execution were performed by this reviewer.

## Source conclusions

- Producer `defer` clears the owned loading slot before success/error reaches coalesced waiters. A waiter can retry without joining a completed failure. Both producer and original caller cleanup check the retained selection UUID; late old cleanup cannot erase a newer load.
- A new selection withdraws the old UUID and slot before cancelling the old task, including existing-content and preload fast paths. Retired resolver results cannot publish over those fast paths. Identical accepted display reuse with no pending task preserves its UUID and already-completed accessors.
- Pending `getContent()` captures selection UUID and requires both unchanged UUID and object identity after awaiting. Navigation away and back through `load(url:)` cannot revive a retired read even if the identical object is republished. A same-URL replacement object is also rejected. Original task errors propagate rather than being replaced by successor content.
- `Task.checkCancellation()` precedes all load mutation, so a request already cancelled at entry cannot retire the active owner, consume preload, or change page/content. Joined cancellation does not cancel the shared unstructured resolver. This matches the selected hotfix's bounded contract.
- The final-read coalescing guard also rejects a task already marked cancelled. An explicit later request can retire that slot and create a fresh owner instead of joining doomed work; ownership guards keep the old completion separate.
- The public `load(url:)`, `ContentResolver` type, global optional resolver, original request URL, `countsAsHistoryVisit: true`, and `"ReaderContent.load"` source argument are retained. The candidate uses main's existing resolver rather than importing the hotfix's different resolver seam or removing provider behavior. Main's transient blank suppression and title flow remain present.

## Explicit limits

Read all 12 new cases in `Tests/LakeOfFireTests/ReaderContentSelectionOwnershipTests.swift`, blob `a2359fb23f730b3f8912ea47f639a22cbffd6fd4`, after author creation. They exercise production ReaderContent via its retained static resolver; unmanaged HistoryRecord fixtures, checked visit/source arguments, per-test resolver restoration, and bounded resolver gates are present. Cases cover preload/existing fast-path retirement, running same-URL coalescing, already-cancelled preload/uncached requests, producer error cleanup/retry, reentrant replacement, unchanged-display reuse, same-object ABA through load, ordinary pending-accessor success and original error after replacement. No concrete compile/API error was found by inspection.

The same-object ABA case filters only samples whose transition already happened and does not require at least one such sample. Task priorities and 32 waiting readers widen the race but do not deterministically force a late accessor; the case can pass vacuously if every reader wins that schedule. The coalesced retry case likewise does not explicitly force retry before the initiating caller resumes. These are coverage limits inherited from the selected-hotfix test approach, not evidence of a production defect. The new file is within the SwiftPM test target's directory, but no explicit Xcode project file reference was present at final read; native discovery remains unverified.

The retained UUID identifies selections admitted through `load(url:)`. Public direct assignments to `content` or `pageURL` do not rotate it. Object identity rejects a different direct replacement; a direct A→B→same A assignment without `load` is outside this selection guarantee. This is an existing mutable API boundary, not a new port defect.

There is a concrete production caller outside that boundary: `Sources/LakeOfFireLibrary/Library/LibraryFeedView.swift:675` (`refresh`) clears/assigns `readerContent.content` at lines 692/704/713 and awaits `navigator.load(content:)`. `Sources/LakeOfFireContent/Reader/WebViewNavigator+ReaderContent.swift:26` first awaits `ReaderContentLoader.load(content:)`, then may await its previous-content prefetch at line 39, before issuing navigation at line 85. It does not admit a ReaderContent selection or preload at that point. During those waits, the owner-only patch cannot guarantee that the direct assignment retires a prior pending ReaderContent resolver. This limits the production scope of the change; it is not resolved by the bounded port. Direct assignments in ContentList/HorizontalList DEBUG previews are not production evidence.

The global `nonisolated(unsafe)` resolver remains shared among instances and tests; this port does not introduce per-instance resolver isolation. No new resolver concurrency safety is claimed. Tests replacing that resolver must restore it and avoid overlap with other users.

Cancellation after a load has been admitted does not automatically cancel or withdraw its producer in this candidate, as in frozen main and selected hotfix. The final remote adds selection lifetime, intent/handoff, invalidation, cancellation handlers and post-resolution validation. Those broader contracts, mounted title lifetime and durable rename ownership are explicitly excluded from this review and are not represented as ported.

Runtime scheduling, Swift compile/API validation, Xcode target discovery, native integration and Realm invalidation behavior remain unverified. No readiness claim follows from source parity.

## Final test revision resolution

Reread the complete final test source, blob `4443746bfdf27cc6f1237a74aed8978b23c9c42f`. It now contains 11 test methods. The author removed `testCompletedReadersRejectReturnToTheSameObjectAfterNavigation`, the `transitioned` filtering, and priority hints. `samplePendingReaders` now returns every pending read directly and is used only by unchanged-display reuse; that case asserts every returned value is non-nil. Earlier 12-case blob evidence and its coverage critique above are preserved as historical review evidence, not claims about the final test file.

No new source/API defect was found in the final test revision. Production ReaderContent remains unchanged at `c2793b7ac93eec5eeaf09df0fca018e56c14ee36`. Removing the vacuous case resolves its misleading coverage assertion; a deterministic runtime oracle for a queued accessor encountering navigation away and back to the identical object remains missing. The selection-ID reasoning is source evidence only. The coalesced retry schedule limitation, direct-setter caller boundary and all compile/runtime/discovery limits remain. No source edits, commits, build or test execution occurred during this follow-up.
