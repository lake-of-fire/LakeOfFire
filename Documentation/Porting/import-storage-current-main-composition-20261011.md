# Import storage composition — 2026-10-11 08:08 UTC

Destination #138 reviewed at d1c08ee6aecc8103fcc9179fc3ef35b524024049, tree ea9698b0a2cb92019155a48929314c061e3f9535. Older #50 source ce8200d810d35b6ff18e0da2fe33341e5d87b73b.

## Actual adaptation
The old stack's ReaderFileManager differs in 92 regions and lacks newer receipt-scoped inventory, drive factory and final publication handling. It was not copied wholesale. Replaced only its collision/copy region and retained captured InventorySelection, configuration/drive checks, security-scoped access, private Realm opening, full-refresh completion and final-row re-resolution.

Three focused helpers preserve occupied original/hash-suffix destinations, retry exclusive-copy name races, reuse identical data, and distinguish directory path/type/file boundaries. Symlink leaves count as occupied names; relative parent admission rejects obvious traversal and symlinked parent paths. Directory manifests hash path/type/size/content, empty directories and literal symlink targets instead of concatenating only file bytes.

The adapted storage helper adds a caller admission closure, defaulting to no additional policy for standalone callers. ReaderFileManager supplies its captured inventory validator. Entry, comparisons after suspension and each copy admission reject a replaced owner. Successful physical copies are never rolled back; the manager separately rejects stale indexing/publication.

## Evidence and regression source
- Fresh SwiftCloudDrive main c5ef6ad68b62c9d418cca73378d3a7ae0e834eac inspected: CloudDrive.upload delegates to CoordinatedFileManager.copyItem and FileManager.copyItem without removal/replacement. Its final accessor has no originating inventory callback.
- Eighteen resolver, 21 original storage/manifest and 12 composition methods carried; two admission regressions added (retired entry and replacement during suffix generation). All 53 UNCOMPILED/UNRUN.
- Existing actual ReaderFileManager import/inventory tests remain unchanged and are not claimed executed by this composition.
- No builds, tests, native apps, benchmarks, CI dispatch, pins or production changes.

## Still open
- The await into SwiftCloudDrive can outlive the last caller admission check. Final physical-copy admission needs a paired dependency API; current source checks do not create a cross-actor lease.
- Lexical containment is not a directory inode lease. Source/destination mutation during comparison/copy and fully coordinated immutable snapshots still need reconciliation with the remaining #50 snapshot graph.
- No full #50 supersession or native qualification. Next action: compare remaining directory/ZIP snapshot and serving-session prerequisites with newer reader architecture; preserve current ownership APIs.
