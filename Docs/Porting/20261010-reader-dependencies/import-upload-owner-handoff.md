# Upload/import ownership follow-up — October 10, 2026 (America/Toronto)

Source-only review of Lake draft #138 at
`39567c8f3d74838c7d73d64e1e4fd6d8306a50e4`. LakeKit #13 remains
`f3d14acb8c8410ca4ff6f25f5ade5bbd346429b7`; neither root pin was changed.
This review narrows the existing import gap; it does not implement a second import stack.

## P1: import side effects can outlive the selected drive

In `Sources/LakeOfFireContent/Files/ReaderFileManager.swift`, private `importFile`
selects a drive at entry, then awaits `rootRelativePath(forImportedURL:drive:)`, which
invokes registered asynchronous destination processors. It does not capture or validate
an inventory receipt. If the manager's drive changes while that processor is suspended,
the resumed request can call `createDirectory` and `upload` on the displaced drive.
Only the later `refreshFilesMetadata` checks current drive membership. Rejecting that
scan does not undo the physical copy that preceded it.

The `ensureImported` repair in `39567c8f` validates selection before invoking this
new-copy branch, but does not carry that selection into its implementation. The public
picker entry also calls private `importFile` directly. Existing-file publication is
repaired; upload ownership remains open.

The checked-in `Package.resolved` selects SwiftCloudDrive
`0a84ea27d394fe0ed92e9b7809d84cfaa1942442`, matching the clean local checkout inspected
read-only. Its `CloudDrive.createDirectory` and `upload` check connection, then delegate
to `CoordinatedFileManager`. The coordinated copy calls `FileManager.copyItem` without
an owner-admission argument. A connection check is not the manager's drive/account receipt.
A caller check before an await cannot prove admission inside that eventual copy.
SwiftCloudDrive is outside this task's assigned 13-repository partition and was not edited.

## P1: completion can adopt a successor inventory

After targeted scanning, `importFile` opens Realm, awaits reader URL processors, obtains
a managed `ContentFile`, and awaits a forced full refresh before returning `content.url`.
These continuations do not retain the import's receipt. A drive replacement after the
targeted scan can therefore make the full refresh capture a new selection rather than
reject the original import. The returned record is not re-resolved or checked for deletion
after that refresh. This is a source-level counterexample, not an observed native failure.

Actual consumers include the picker in `BookLibraryView` and
`BookLibraryViewModel.open(publication:readerFileManager:readerPageURL:navigator:readerModeViewModel:)`.
That method uses the import result to load reader content and navigate; successful return
is an externally meaningful completion boundary.

## Preserve the pending owner and compose the repair

Fresh GitHub observation keeps pending Lake #50 open at
`0b91431f0fe04c45b24b08b427a5df66e87661b9`, base main. Its import implementation already
uses `ReaderFileImportStorage.install`, with filesystem-type handling, package-manifest
identity, exclusive collision installation and cancellation checks. It also reopens Realm
after full refresh and rejects deleted or mismatched final records. These are pending-source
improvements, not selected-main or runtime proof. Its storage helper still receives a drive
without this candidate's inventory receipt, so it does not close replacement ownership.

Next owning tranche should compose that existing helper, carry one captured import selection
through destination processing/indexing/completion, and define physical-copy admission with
the SwiftCloudDrive owner. Stable record identity should cross the final await instead of a
managed object. Do not transplant only the helper and call upload ownership complete.
Already-installed bytes must be preserved on cancellation; no destructive rollback is proposed.

Required regression sources: replacement while a destination processor is suspended;
replacement before physical copy admission; replacement after targeted scan but before
final refresh; tombstoned final row rejection; successful current-owner import. Existing
`DownloadableBookLibraryImportTests` covers successful cached-copy and already-installed
publication, not these interleavings. Native/platform execution remains a separate gate.

## Verification and limits

Read the current import/destination/publication implementations, direct callers, successful
import tests, pending #50 import/storage helper and the exact resolved SwiftCloudDrive
copy boundary. Ran source searches, object/status inspection and `git diff --check` only.
No build, test, benchmark, package resolution, CI, native app or generator ran.
No SwiftCloudDrive, Core, Realm, parent source, settings, pin or original checkout was edited.
Other import recovery/snapshot/deletion paths and whole EPUB coverage remain unreviewed here.
