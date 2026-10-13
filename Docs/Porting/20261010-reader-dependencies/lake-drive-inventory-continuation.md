# Lake drive inventory continuation — 2026-10-11

Exclusive write ownership: `LakeOfFire/Sources/LakeOfFireContent/Files/ReaderFileManager.swift` and new `LakeOfFire/Tests/LakeOfFireTests/ReaderFileInventoryOwnershipTests.swift`. No document/title/library/sidecar source, deleted validator, manifest, migration pin or existing deletion test was changed. Changes remain unstaged; no commit/push/PR creation performed.

## Exact evidence boundary

- Main frozen target: `8985bf92b9504d53e00025e4054b3aa97f876e45`.
- Current task branch / [PR #138](https://github.com/lake-of-fire/LakeOfFire/pull/138) starting HEAD: `338acd87af421120a523bfb884b5ece9c7247a10`.
- Preserved preparation implementation: commit `88fb3bd85d54d1ae88bb965db94273d65a1a055a`; changes retain its optional cloud / required local preparation, pre-entry cancellation and initialization UUID admission.
- Current hotfix endpoint `refs/remotes/audit/final-v3-hotfix`: `6e492b3e2a65b4d8a7e49a0e196152d82b6bdc04`.
- Pending upstream [#50](https://github.com/lake-of-fire/LakeOfFire/pull/50): `0b91431f0fe04c45b24b08b427a5df66e87661b9`. Its scope-keyed task and lock-protected orphan receipt remain relevant newer upstream architecture; its DownloadableBookGridCell importIdentity was untouched.
- Hotfix-only [#137](https://github.com/lake-of-fire/LakeOfFire/pull/137), captured head `8b9d8381ce7561625452545b99260b29aaf81f37`, now present in hotfix history. It is not a port to main.
- Fixed provenance window remains inclusive 2025-10-10 through 2026-10-10. Relevant final-hotfix manager history was read: `8b9d8381ce7561625452545b99260b29aaf81f37` (2026-10-10 inventory/status), `8cc5e301e4167a4313255226ae858761092a0b7d` (2026-10-10 inventory admission), `6c171ac1f453d619edfb28e6365532f4e52cbd26` (2026-10-06 missing-entry admission), and original initialization/storage generation work. This continuation is not a new whole-repository source window.

## Verified behavior gap

At main and the initial #138 head, one global refresh task and debounce timestamp are shared across drive tuples and Realm configurations. A replacement caller can join old work or skip the new tuple's scan. The scan chooses live manager state, performs per-file Realm writes after enumeration and URL mapping awaits, publishes `files` before orphan cleanup, and enters the orphan transaction without a selection receipt. A stale scan can therefore revive/create metadata, publish old-drive files, and tombstone rows using obsolete inventory. Validating only initialize's return cannot reject those effects.

Hotfix `MetadataRefreshSelection` carries drive objects, initialization ID and Realm configuration. Its `validateMetadataRefreshSelection` is called at actor/write boundaries. #50 independently supplies a lock-backed inventory receipt around orphan mutation. These are behavioral evidence; neither pending PR already implements the complete preparation/selection integration made here.

## Worktree repair

- `InventorySelection` captures the exact local/cloud drive objects, Realm configuration and UUID receipt. `InventoryOwnership` serializes invalidation against the admitted synchronous metadata/orphan mutation closures.
- Drive and explicit Realm override setters invalidate **before** replacement. A healthy initialization attempt invalidates old scans before async preparation begins, including when preparation later fails. Already-cancelled entrants still do not invalidate work. Suspension invalidates and cancels active producers.
- The resolved Realm backing identity (in-memory identifier or standardized file URL) is compared at admission. Capture changes the receipt when the resolved backing identity changes, so a default configuration replacement cannot join the old backing's task. Explicit override assignment always advances the receipt, even for the same backing identity.
- Refresh tasks, follow-up flags and debounce state use the captured receipt. A new tuple/configuration starts an independent task. Each task has an additional UUID so a cancelled predecessor's deferred cleanup cannot remove a successor entry. Debounce now requires a successful publication timestamp belonging to the exact receipt; each admitted pass clears its prior marker, and only final successful files publication installs a new timestamp. Failed replacement/forced scans cannot suppress an immediate retry. Same-receipt concurrent refreshes still coalesce; force still requests a trailing pass.
- The recursive real scan carries one captured selection. It validates before enumeration processing and after URL mapping/recursive awaits, before the per-file actor write, inside its synchronous write closure, around processor callbacks, after final Realm opening, inside orphan mutation, and before final MainActor publication. Mutation metadata remains explicitly refreshed in the same Realm transaction.
- Accepted observations from currently installed drives invalidate scan and orphan authority and start a forced fresh receipt. Events from displaced drive objects are ignored. This avoids observation-triggered debounce drops and old-receipt joins.
- A missing directory yields incomplete scan (`nil`) instead of a partial array eligible for orphan deletion. Full inventory refuses to clean up or publish that incomplete result. Recursive incompleteness is propagated. This is fail-closed and differs from hotfix's more complete per-root retention policy.
- `files` is assigned after successful orphan cleanup and final receipt validation. Initialization still acknowledges preparation only; it schedules refresh in the background and does not promise inventory settlement.

## Cancellation and data flow

Request captures storage/configuration receipt → actual CloudDrive enumeration and package/directory traversal → asynchronous reader URL processors → receipt check → RealmBackgroundActor cached Realm → receipt-locked synchronous metadata/journal mutation → processor pre/post admission → captured references → MainActor Realm resolution → receipt-locked orphan/journal transaction → MainActor receipt check → `files` publication.

A replaced receipt throws `CancellationError`. A cancelled caller checks cancellation before capture and after waiting; it does not revoke shared producer ownership. Suspension explicitly cancels producers and invalidates receipts. Background processor/scan errors still propagate and non-cancellation producer errors retain existing logging. An already-cancelled waiter cannot create a follow-up request.

## Runtime regression source

New `ReaderFileInventoryOwnershipTests.swift` belongs to the existing package `LakeOfFireTests` path and uses the existing runtime mutation-tracking test helper. Instance seams suspend the actual filesystem/Realm scan rather than supplying replacement inventory results. Bounded XCTest expectations avoid sleeps and polling. Entry races producer completion; seam release and task-result observation each have a five-second bound. Failure paths release gates, cancel producers and attempt bounded joins, so an unreachable seam or hung successor reports a failed fixture instead of indefinitely blocking the suite.

1. `testReplacementDriveStartsItsOwnScanBeforeOldMetadataWriteResumes`: original real enumeration is held before its metadata actor write; replacement drive scan completes before original resumes; only replacement metadata/files survive.
2. `testReplacementConfigurationRejectsOriginalPerFileWrite`: same physical drive, different in-memory Realm; successor indexes into the new Realm and old Realm remains empty.
3. `testReplacementBeforeFinalPublicationCannotTombstoneOriginalOrPublishOldFiles`: original empty scan held before final stage; replacement prevents orphan tombstone and file publication.
4. `testNewDriveReceiptBypassesPreviousCompletedScanDebounce`: immediately replaced drive is scanned despite old successful scan timestamp.
5. `testFailedReplacementReceiptRemainsImmediatelyRetryableWithOldFilesVisible`: real old inventory publishes; injected scan-boundary error fails the first replacement pass; an immediate ordinary retry performs a fresh real scan and publishes replacement metadata. Scan count includes failed attempts.
6. `testFailedForcedPassInvalidatesEarlierReceiptPublicationDebounce`: a forced pass fails after earlier same-receipt success; immediate ordinary retry re-enumerates and publishes a newly added file.

No builds, tests, benchmarks, native apps, installs, validation generators or CI dispatch ran. **Not run by request.** `git diff --check` passed for the two owned paths. Package source membership was inspected statically; compilation, discovery and native execution remain unverified.

## Classification and unresolved boundaries

- **Genuinely missing → implemented locally, unverified:** drive/configuration/initialization receipt across the manager's own metadata transaction, orphan transaction, UI publication and replacement task/debounce scheduling.
- **Partially ported:** observation invalidation and suspension lifecycle. A full lossless request queue with batch-specific completion, forced replay and prompt caller-isolated cancellation has not been imported. Same-receipt forced callers can still wait for later work; same-receipt ordinary manual refresh retains existing debounce behavior. Initial suspension is not an explicit "stay suspended" queue gate, so new callers during suspension can still request scans.
- **Unresolved processor API:** `fileProcessors` are opaque async closures accepting live managed ContentFiles. Pre/post selection validation cannot prevent an uncooperative callback from suspending, losing storage ownership and then writing internally. Its internal write admission belongs to an API/processor-owner adaptation, particularly EPUB enrichment. No claim of complete end-to-end processor fencing is made.
- **Unresolved filesystem admission:** vanished leaf files and local/cloud readability changes can occur between enumeration and metadata mutation, even if storage generation stays unchanged. The hotfix missing-file/presence and per-root completeness policy was not transplanted. This change rejects obsolete storage authority, not all concurrent filesystem edits.
- **Unresolved global configuration symmetry:** checks follow hotfix backing identity (file URL / in-memory identifier). Global configuration changes with the same backing URL but different schema/account/encryption settings have no independent producer generation exposed to this manager. Explicit override replacement is fenced; a broader global owner contract needs review.
- **Unresolved concurrency/API compatibility:** drive properties remain the existing nonisolated mutable unchecked-Sendable API. The receipt lock protects mutation admission; it does not turn arbitrary simultaneous property access into a generally thread-safe configuration API. A source reviewer should assess actor confinement and lock-held synchronous metadata cost. No performance claim was measured.
- **Unreviewed elsewhere:** import/download/read/delete captured selection, complete specialized enrichment/sidecar flow, migration completion, full test matrix and all other dated source paths remain outside this continuation.

Only manager-owned durable mutation/publication and replacement-scheduling contracts are proposed for parent review. This is a bounded repair and not Lake inventory-family closure.


## Independent review repairs

Read `lake-drive-inventory-independent-review.md` (review of predecessor manager blob `317f3d4559496e4320f355a39014ec2c4287c234` and test blob `e497ed8b1a540aa9a841b66c7ba927f7a13d627d`). Its P1 failure-sensitive debounce and P2 unbounded fixture gates were valid findings and have been repaired locally as described above. Gate deadlines establish fixture liveness only; timeout is a failing result, never a success criterion. The two added failure/retry tests use no sleep or deadline acceptance. No runtime tests were run; the revised blobs need independent source review and compilation/execution remain unverified. Broader unresolved boundaries listed above remain open.
