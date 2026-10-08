# History demotion: committed reads and final storage admission

## Source and scope

Base: LakeOfFire `v3-hotfix` at `f6801f38327f1d5e0b4988a7a1a647645b49bd93`, tree `d5c72d37235cd216a6c54d0ce329d6831ee05872`. That tree is identical to Reader #312's Lake pin `78c1777aa564bf8f10230ae9d366000302c1515b`; this does not import main's EPUB architecture or the separate media/transcript branch.

Initial PR #120 commit `c41b6a951e86e4983454fd50087b3cb8d5ab91e1` is superseded by its reviewed creation-path refinement.

One existing production method changes: `HistoryRecord.refreshDemotedStatus`, in `Sources/LakeOfFireContent/Web/HistoryRecord.swift`. The complete original file was verified as blob `b472c4b6aaae308938990896e363ead58dd88a99`; the complete corrected file is `64906579545e83ad3dad0c257eebae49c2b18c8c`. All unrelated declarations remain intact. The new native file is `adf3c0d5842e98afdc88ff4182adc7fbfcc51edf`.

The review read the selected History/Bookmark models, loader entry points and references, storage admission and owned-write contracts, the prior metadata correction, and current integration/qualification reports. It does not claim an exhaustive audit of every Lake or Reader file.

## Findings and correction

### Provisional visibility or deletion could suppress the request

The initial guard read `self.isDeleted` and `self.isDemoted` from the live HistoryRecord before acquiring an independent writer. A caller sharing a Realm with another open transaction could observe provisional deletion or visibility and return without ever reevaluating committed state. The other owner could later roll back, leaving a missed refresh.

Capture the existing reference and storage admission, then evaluate the existing early-return predicate on a short-lived committed snapshot. Preserve the no-op optimization for a genuinely committed visible/deleted row. The snapshot does not cross write admission. A missing committed row is not accepted as a no-op: a managed insertion may still be awaiting its owner's commit. Admit the existing write and resolve the row there; do not recreate it after rollback. Final mutation still resolves the current row inside the owned transaction.

### Independent bookmark writes could become durable history decisions

In split-store configurations, the final writer refreshed and queried a live bookmark Realm. An independent provisional insertion, deletion or URL edit could be persisted as a History demotion/promotion even if the bookmark owner later rolled back. A refresh notification could also open such a writer after the check.

Refresh an idle separate Realm, then use its committed snapshot for the unchanged indexed membership query. If bookmarks and history share the actual owning Realm, keep using that writer's live view: those model changes share the same commit/rollback boundary. The correction does not normalize URLs, change alias policy, alter the five eligibility flags, or make cross-store commits atomic.

### Refresh and metadata callbacks could outlive admission

A synchronous refresh callback can retire captured storage or alter the History row after its earlier guard. Resolve the history row after that callout and revalidate original storage before using it. Revalidate again after metadata/journal callbacks, before committing, so storage withdrawal rolls back this operation's fields and generation together.

A small local validation function reuses existing admission and Task-cancellation APIs. An explicitly supplied bookmark configuration remains the operation's configuration; merely changing the global loader default does not invalidate an otherwise valid explicit store. No post-commit cancellation check is added, and successful durable completion stays successful.

These are source-reproduced visibility/journaling failure paths. No observed production incident, corrupted Unmark support or genuine account-switch failure is asserted. The repair affects future demotion refreshes; it does not bulk-rewrite previously persisted visibility.

## Verification actually executed

Linux x86_64, Swift 6.2.1. Complete strict concurrency and warnings as errors in each configuration:

| Configuration | Corrected method | Exact original method |
| --- | --- | --- |
| Swift 5 / unoptimized | 26 passed | 16 passed / 10 expected failures |
| Swift 5 / optimized | 26 passed | 16 passed / same 10 failures |
| Swift 6 / unoptimized | 26 passed | 16 passed / same 10 failures |
| Swift 6 / optimized | 26 passed | 16 passed / same 10 failures |

There are 26 distinct controlled scenarios, not 104 unique tests or ten independent product defects. All eight final runs have zero missing, duplicate or skipped methods and preserve command/process exits. The runner compiles the exact complete production method with explicit Realm, query, storage-identity, refresh, journal and write-settlement collaborators. Real Swift task cancellation is exercised. These collaborators are not the Realm SDK, a native predicate engine, real filesystem replacement or CloudKit. No full LakeOfFire module or assembled Reader qualification is inferred.

The first XCTest discovery build rejected a stateless test-case carrier under strict concurrency and executed zero tests. After that fixture was corrected, two test histories were refined to use the same original/corrected opening boundary and a real-model-shaped soft deletion. The earlier passing test draft is not final evidence. Final receipts bind the exact final tests and source, and the setup/draft runs are retained separately.

## Second-pass isolation controls

The same assertions run against single-boundary reversions:

| Deliberate reversion | Pass / expected failed scenarios |
| --- | --- |
| Live History preflight | 24 / 2 |
| Live independent bookmark view | 22 / 4 |
| Remove post-refresh and post-journal admission | 23 / 3 |
| Resolve/check History before refresh callback | 25 / 1 |
| Freeze the actual shared owning write | 24 / 2 |

The first four failure sets have exactly the original ten-case union. The last control demonstrates why a blanket frozen-read rule is wrong for the owned shared-store case; it is not an original-code defect. The second pass also retained explicit-store routing, no-op generations, current committed changes, commit failure and cancellation after success as positive controls. Production remained unchanged during these isolated controls.

### Own-draft regression caught before final handoff

The first publication's committed preflight returned early when no stored row was visible. That is wrong for a managed History row newly inserted in another active transaction. Two added positive histories exercise that owner committing and rolling back. The original branch passes both; initial publication `c41b6a95` fails both (24 pass / 2 fail in the expanded 26-method suite).

The refined implementation treats absent committed state as requiring final write evaluation, not as evidence of a no-op. A committed insertion is refreshed, and a rolled-back insertion is neither recreated nor journaled. Existing committed visible/deleted no-ops remain unchanged. The expanded matrix was rerun completely on the refined production source, and all five isolated controls were rebuilt against that same source. Earlier 24-method results and initial publication blobs are retained as historical scope, not substituted for the final matrix. This is an own-draft regression correction, not another original-branch bug.

Complete corrected production and native files frontend-parse with and without DEBUG. Parsing is not Apple SDK typechecking.

## Native companions and remaining gaps

Fourteen actual-Realm methods are authored in `Tests/LakeOfFireTests/HistoryDemotionCommittedStateTests.swift`, using existing Bookmark/HistoryRecord models, explicit unique in-memory configurations, the ordinary mutation policy and awaited cleanup. No new Object class or production hook is introduced. Initial-history held writes are rolled back through the existing loader gate after committed preflight; those cases do not claim native queued-write admission coverage. Independent bookmark transactions remain open through the history operation and are then rolled back.

**Native Apple compilation, actual Xcode discovery and execution have not run here.** Native filesystem-retirement/refresh-notification schedules and full application visibility behavior remain additional qualification, not covered by the portable counter-based admission model. Explicit-store, normal/no-op, committed deletion, current eligibility and journal assertions are retained in the native source.

Two added native companions cover pending History creation commit and rollback. They use the existing loader gate to settle the producer before independent write admission; the rollback assertion queries Realm rather than reading a potentially invalidated wrapper.

Required Reader source: `Vendor/LakeOfFire/Tests/LakeOfFireTests/HistoryDemotionCommittedStateTests.swift`.

```
HistoryDemotionCommittedStateTests/testProvisionalBookmarkDeletionDoesNotDemoteCommittedHistory()
HistoryDemotionCommittedStateTests/testProvisionalBookmarkInsertionCannotPromoteHistory()
HistoryDemotionCommittedStateTests/testProvisionalBookmarkURLCannotHideCommittedMembership()
HistoryDemotionCommittedStateTests/testProvisionalHistoryDeletionCannotSuppressCommittedRequest()
HistoryDemotionCommittedStateTests/testProvisionalVisibilityCannotSupplyCommittedNoOp()
HistoryDemotionCommittedStateTests/testCommittedVisibleHistoryRemainsANoOp()
HistoryDemotionCommittedStateTests/testExplicitRefreshReconsidersCommittedVisibility()
HistoryDemotionCommittedStateTests/testCommittedBookmarkDeletionIsStillObserved()
HistoryDemotionCommittedStateTests/testEligibilityCommittedBeforeAdmissionUsesCurrentHistory()
HistoryDemotionCommittedStateTests/testSharedRealmPreservesOrdinaryBookmarkAndNoOpSemantics()
HistoryDemotionCommittedStateTests/testExplicitBookmarkStoreDoesNotFollowGlobalReplacement()
HistoryDemotionCommittedStateTests/testMismatchedExplicitAdmissionRejectsWithoutHistoryMutation()
HistoryDemotionCommittedStateTests/testPendingHistoryCreationIsRefreshedAfterItsOwnerCommits()
HistoryDemotionCommittedStateTests/testRolledBackHistoryCreationIsNotRecreatedOrJournaled()
```

## Composition and qualification ownership

Keep draft. Register the new test path and fourteen identities in Reader's Project.swift and both required-method inventories when deliberately selecting this component. Do not alter a currently executing immutable native tuple. No root pin, active inventory, generated workspace, model schema, public API, journal format, clock, lock or coordinator changes in this component.

Catch-up is separate from this increment: BigSync #136 is now merged into #131 (`abf3d465113c6bd332d06bc72f144ca25529dac9`), with 48/48 native macOS methods reported at its published child `cac7114809cbec8debc8237b4f62711f2385a398`. That reported result is not a new test run here and does not qualify Lake, Core #477 or Reader. Reader #312 still selected BigSync `1ded43c0` at this review's read. Parallel Reader #313 also remains based on #286, not a successor that automatically includes #312; this review does not merge those application candidates. Core #477 remains a separate committed-metadata follow-up at `373d804174208bc6cb57b0c19d084f647894ff92`.

No protected-target merge, production CloudKit mutation, deployment, signed journey, Mac UI/performance run or release authorization occurred in this review.
