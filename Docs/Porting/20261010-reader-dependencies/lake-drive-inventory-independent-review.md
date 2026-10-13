# Independent drive inventory review — 2026-10-11

Read-only review of `ReaderFileManager.swift` candidate blob `317f3d4559496e4320f355a39014ec2c4287c234` and new `ReaderFileInventoryOwnershipTests.swift` blob `e497ed8b1a540aa9a841b66c7ba927f7a13d627d`, against main `8985bf92b9504d53e00025e4054b3aa97f876e45`, selected hotfix `036d4193078016db0becdf91b86dd34fb1d579e0`, separate in-window remote hotfix `6e492b3e2a65b4d8a7e49a0e196152d82b6bdc04`, and pending upstream [#50](https://github.com/lake-of-fire/LakeOfFire/pull/50) `0b91431f0fe04c45b24b08b427a5df66e87661b9`. Starting candidate branch head is owned [#138](https://github.com/lake-of-fire/LakeOfFire/pull/138) `338acd87`. Other concurrent patches were not reviewed. No edits to either reviewed file.

## Historical findings on first reviewed blobs

### P1 — Failed replacement scan is debounced as though the new receipt completed

`Sources/LakeOfFireContent/Files/ReaderFileManager.swift:720` returns immediately when global `files != nil` and a same-receipt start is within two seconds. `:726` records that start before scanning; failure `:782` throws without removing the timestamp. `files` remains the previous receipt's collection until successful publication `:780`.

Concrete sequence: old local drive scan publishes files → install new local drive (receipt rotates) → new receipt's first enumeration, processor, Realm opening or orphan write fails → caller catches and immediately retries ordinary refresh → receipt matches the failed attempt's timestamp and old receipt still supplies non-nil files → method returns success without enumerating/indexing/publishing the new tuple. A failed forced refresh on an already-published receipt similarly suppresses an immediate ordinary retry. Main and #50 already share failure-sensitive start-time debounce; merely keying it by the new receipt does not meet the new generation-owned completion contract. This is an incomplete port, not a claim that it originated exclusively in this patch.

Required repair: gate debounce on a successful publication owned by this receipt and time that completed publication, or ensure failed attempts cannot supply its successful-completion/debounce marker. Add real-owner regression for failed first scan after replacement with old files still visible, followed by immediate ordinary retry. No sleep/timeout-based acceptance is needed: inject an actual scan/read error, then succeed and count/index the fresh pass. This finding was sent to parent early.

### P2 — Regression gates can hang indefinitely instead of reporting a failed counterexample

`Tests/LakeOfFireTests/ReaderFileInventoryOwnershipTests.swift:22` awaits an unchecked-duration continuation for entry; `:19` similarly waits for release without a bound. First three tests await entry before joining the producer. If production scanning throws/cancels before reaching the seam, or a fixture path ceases to be indexable, the original Task completes but entry never happens, so the test hangs forever and never observes its error. Successor scan can also hang before catch releases the first producer. Actual gated interleavings are useful; use bounded expectations/entry race with producer completion and guaranteed release/join on failure. No runtime execution was performed to assert a current hang.

## First-snapshot reviewed behavior classifications

| Behavior/path | Source evidence and classification |
| --- | --- |
| Receipt construction / exact drive objects | Candidate `InventorySelection:104`, capture `:680`, validation `:691`: exact local/cloud object pair, UUID and configuration snapshot. Override/drive setters invalidate before replacement; initialize `:264` invalidates before preparation; suspension `:307` invalidates/cancels producers. **Focused generation admission authored**. Selected/remote hotfix `MetadataRefreshSelection` additionally carries initialization ID; candidate entry invalidation is a bounded alternative for scans already running when initialization begins. |
| Storage identity | File URL / memory identifier equality checked at every admission. Explicit override assignment rotates even same backing. **Partial**: mutable global same-backing schema/encryption/account/config replacement and A→B→A global identity round-trip lack independent generation signal, as author report acknowledges. This is not captured-account fencing. |
| Metadata write | `:918` seam then validation; cached captured Realm at `:925`; lock held around synchronous mutation `:930`; existing record lookup happens inside Realm write; explicit metadata refresh retained in setMetadata / add path. **Focused stale-receipt write admission authored**. Lock has no await inside operation and invalidation cannot pass an admitted synchronous mutation. Lock is released before asynchronous Realm commit finishes; its linearization is mutation admission, not guaranteed rollback of a previously admitted transaction on subsequent replacement. No general transaction-owner claim. |
| Orphan cleanup/publication | `:749` seam; captured Realm opened; current receipt checked; orphan query selected inside write/lock `:766`; explicit tombstone metadata refreshed `:772`; publication follows successful transaction and final main-actor validation `:779`. **Focused stale-receipt orphan/publication admission authored**. Baseline main published before orphan write; #50 supplied lock-backed orphan receipt but earlier publication. |
| Queue/successor cleanup | `inventoryTasks` keyed receipt; additional task UUID checked in producer defer `:730`; producer cleans its own entry before completion wakes consumers; `force` sets same-receipt follow-up and repeat consumes it; replacement receipt can start while old scan awaits seam. **Focused owner/successor cleanup authored**. Failure drops pending same-receipt follow-ups; no batch-specific/lossless request queue or prompt isolated cancellation promised. |
| Debounce | Replacement receipt bypasses a previous receipt's successful scan timestamp. **Incorrectly partial on failure**, P1 above. Existing files are not receipt-owned successful publication evidence. |
| Suspension / initialization | Already-cancelled refresh/initialize checks precede displacement. Suspended callback invalidates existing producers; resume schedules refresh. Initialize preserves usable tuple until both preparation stages complete; background scan remains separate from preparation acknowledgement. **Partial lifecycle**: no persistent stay-suspended gate, inventory-completion startup acknowledgment, or deterministic new-init/failure/suspension runtime regression in this test file. Calls during suspension may start a new receipt. |
| Observer | `:1475` rejects displaced-drive events; current event invalidates and starts force. **Focused event refresh authored**; invalidation occurs when queued main-actor callback runs, not synchronously on arbitrary notification thread. No broader event-ordering promise. |
| Missing directory | Scan returns nil on missing directory and propagates recursive nil; full inventory refuses orphan cleanup/publication. **Intentional bounded fail-closed divergence** from hotfix richer per-root completeness/retention. Current same-selection vanished leaves and metadata revival remain author-reported missing filesystem admission. |
| Processors | `:960` pre/post receipt validation surrounds actual async fileProcessors, preserving signature. **Unresolved**: uncooperative callback can await then write internally before returning; it receives live managed rows and no captured write-admission contract. No full processor API closure. |
| Import-side partial publication | Existing `refreshMetadataForExistingLibraryFile:529` awaits selected scan then `publishDiscoveredFiles:555` opens Realm/merges UI without carrying receipt; generation can change after scanner return and during publication await. `importFile:640` and stored selection flow remain outside patch. **Unreviewed/open integration edge**, not claimed repaired by full-inventory admission. |
| API / caller compatibility | Public refreshAllFilesMetadata(force:) and CloudDrive callback shape unchanged; override-friendly internal refreshFilesMetadata signature retained. Recursive implementation now uses private scanner with shared receipt, deliberately preventing recapture on each recursion. Existing CountingReaderFileManager override fixture remains reachable from full-refresh call. Explicit supplied realmConfiguration now must equal current resolved backing at admission; existing actual import callers supply captured resolved configuration, and obsolete captured requests are rejected. No broad arbitrary-config compatibility guarantee. |

## First-snapshot runtime fixture source review

Four new methods exercise actual CloudDrive temporary directories, production recursion/URL mapping, ContentFile Realm writer, captured main publication and receipt ownership. Config includes Bookmark, ContentFile, ContentPackageFile, HistoryRecord, FeedEntry and existing mutation tracking helper; in-memory IDs are unique and cached background Realms keep their state accessible for assertions. Text files are ordinary supported fixtures; expected title stems follow production setMetadata. Entry/release gate is actor-isolated; mutable continuations do not cross actors unsafely. Main-actor manager/property operations in these fixtures avoid the public unchecked-Sendable property's unresolved arbitrary-thread races.

Test source covers replacement before per-file write, replacement configuration, replacement before final publication and successful prior receipt debounce bypass. It does **not** cover P1 failure/retry, forced trailing pass, ordinary coalesced failure/retry, suspension/resume, initialization during scan/preparation failure, current-drive observations, final transaction admission race, opaque processor internal writes, incomplete recursive enumeration, live payload deletion, or Realm commit failure. No journal-generation assertions specifically verify orphan/per-file no-op behavior. Global processor registries are not independently cleared/restored by these four fixtures, so runner/global registration isolation remains relevant. Gate liveness defect is P2 above. Compilation/discovery/actor-isolation execution is unverified.

## Review process / exact limits

Deterministic review read complete candidate source diff and complete new tests, traced actual full-refresh, existing-file/import and observer callers, then compared selected/remote owner validators and #50 task/lock/debounce paths. Existing normalization override/coalescing/failure methods were read for API reachability. `setMetadata` was read for record/journal effects; specialized imported EPUB enrichment internals and all availability/delete paths were not audited.

Supplementary finite re-read seed `20261011`, Python `random.Random(seed).shuffle` over the seven clusters, order:
1. startup/failure/suspension initialization
2. receipt and storage identity
3. per-file Realm mutation lock
4. real-owner runtime fixtures
5. main/hotfix/pending #50 provenance
6. orphan transaction and publication
7. queue/coalescing and successor cleanup

Tracked reviewed-source `git diff --check` had no diagnostics. No source edits, builds/tests/generators, stage/commit/push or author messages executed. Only this task-root review document is written. The preceding historical assessment applies to the initial exact blobs above. Findings were subsequently repaired and independently re-reviewed below; remaining broad integration limits persist.


## Final repaired-source independent re-review

Repaired manager blob `43c469eb2bc9ccb31f92fdd7e4f4051b9d00b1d0` and tests blob `68b29d2ddd9fcef76f9846aab5df9cbabdfea566` were re-read in full for revised refresh/debounce and fixture plumbing. SHA verification matched parent's announced final blobs. No source edits or author coordination occurred. Fresh Core main `d50a8c2cc66f341bb0a15cbbec3958cef0c1a3d6` evidence was separately read from `core-api-snapshot-d50a8c2c.txt` and recorded in the snippet report; that caller refresh is unrelated to drive runtime verification.

### P1 status — resolved in source, runtime unverified

Candidate now stores `lastInventoryPublishedAt` (`ReaderFileManager.swift:208`) rather than scan starts. Debounce at `:720` depends only on successful publication for the current receipt. Every admitted loop removes any prior marker at `:738`, so a failed forced/trailing pass cannot reuse an earlier success. Marker is assigned at `:783` only after captured orphan transaction and final selection validation complete, immediately after files publication with no intervening suspension. Failure before that point leaves no marker; old visible files cannot supply one for a replacement receipt. Old task cleanup and marker removal remain receipt-scoped and cannot clear a successor's marker.

Two added production-owner tests use a Counting/Failing subclass that throws a typed error for exactly one actual refreshFilesMetadata call and delegates all successful scans to super:

- `testFailedReplacementReceiptRemainsImmediatelyRetryableWithOldFilesVisible`: old tuple publishes, replacement first scan throws, old UI files remain, immediate ordinary retry must make third scan and publish replacement title. No timing wait is used to permit retry.
- `testFailedForcedPassInvalidatesEarlierReceiptPublicationDebounce`: successful same-receipt scan, additional disk payload, forced scan error, immediate ordinary retry must make third scan and publish both payloads.

These test oracles directly cover the two historical counterexamples. Broader failed write/processor/partial-store outcome remains untested, but the marker state transition covers thrown failure from those stages in the inspected source.

### P2 status — resolved for reviewed fixture entry/join paths, runtime unverified

Gate is now MainActor-isolated, with five-second XCTest entry/release expectations. `producerFinished()` wakes entry wait with a failure classification when the producer completes before reaching the seam. `waitForEntry` rejects timeout/early completion, releases the gate, cancels and bounded-joins the producer. `result(of:)` observes completion through a bounded expectation and cancels producer/observer on timeout. The three interleaving tests add guaranteed deferred gate release/cancellation and bounded catch cleanup; successor and cancellation joins also use bounded result helper. This removes the initial indefinite continuation wait described in P2. Cancellation of a noncooperative underlying task is still not guaranteed to settle that task immediately; the helper bounds the test's await rather than claiming general producer cancellation semantics.

All six runtime methods retain actual filesystem scans and Realm writes on successful passes. Class and override helper explicitly retain unchecked Sendable patterns for main-actor XCTest fixture capture; no compilation/runtime guarantee is inferred. No source-string assertions or priority/sleep-based retry oracle was added.

### Final outcome and precise remaining limits

No remaining blocking defect was found in the repaired receipt-owned completion/debounce and revised entry/join source reviewed here. This is a **bounded source acceptance**, not a runtime pass. The original classifications for processor internal admission, same-backing global configuration/account generations, arbitrary-thread mutable drive API, persistent suspension queue, force/failure lossless replay, filesystem leaf existence, import-side partial publication and startup inventory acknowledgment remain partial/open. The historical first-snapshot line references in tables above remain labeled historical; repaired full-refresh source shifts later lines by approximately two or three lines.

No builds/tests/generators, stage/commit/push or source writes were performed. No additional shuffled exploration was required for this small repair; the recorded original finite seed/order remains the source review coverage record. Other concurrent Lake patches, root/Core changes and specialized enrichment were not independently reviewed by this worker.
