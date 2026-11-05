# Porting work: preserve originals during legacy Documents relocation

Draft implementation. This public storage primitive supports the paired Core startup port; it is not independently installed into app startup by this repository.

Source review: Core v3-hotfix ManabiReaderCore.swift blob `c4521dc0ba09cca6a87633d974abf4cbaf191c6d` defers unavailable iCloud identity/container instead of marking migration complete. Main's actual startup implementation at Core #183 still marks CloudDrive initialization failure complete. The availability behavior belongs on main, but both inspected implementations have unsafe copy/delete and directory-merge behavior; that behavior must not be transplanted unchanged.

## Preservation-first adaptation

`ReaderLegacyDocumentsMigration` moves visible root children into Documents. Hidden container metadata remains at root, matching the original top-level scope. Whole source directories, including unpacked EPUBs and their hidden children, remain indivisible. A conflicting directory is recovered beside the existing directory, never merged into an unrelated package.

Use Apple NSFileCoordinator for move/presenter coordination and descriptor-relative `renameatx_np` with `RENAME_EXCL` for the actual commit. A target created after inspection cannot be overwritten by the rename. There is no copy/remove fallback and no recursive deletion. EXDEV, unsupported filesystems/items, changed root/destination, and other failures stop the pass. Already committed moves remain; the next run continues from the remaining sources. Completion is not reported when new visible root children remain after the pass.

Every occupied original and recovered candidate is preserved, including dangling symlinks. Recovery names retain the extension and respect the 255-byte supported-volume budget without splitting extended characters. Exact-byte duplicates are not discarded by this migration: equivalence of content alone does not establish that separate original records may be deleted. The import deduplicator is a different operation.

The shared actor serializes this migration within the process. Pinned directory descriptors and identity rechecks protect root/destination replacement; coordination only serializes cooperative participants. This is not a hostile-writer proof, filesystem snapshot, signed iCloud acceptance, or power-loss durability certification. Top-level symlinks/special files fail without touching their targets; links inside an opaque moved directory are not traversed.

## Qualification

28 XCTest methods use real temporary files, directories, identity/permissions, Unicode names, collisions, links, queues and cancellation. No fake drive, data digest or copy/delete model. The isolated native package compiles the complete production declaration under its real module name in Swift 6 mode with warnings as errors; it intentionally refuses Linux rather than reporting an empty suite as success.

    bash Tools/test-legacy-documents-migration.sh -c debug
    bash Tools/test-legacy-documents-migration.sh -c release

The macOS workflow also typechecks the full helper for iOS 15 simulator. At this initial commit tests are authored and syntax-parsed only; inspect actual CI before claiming native execution. Full Core/Lake/Reader startup, iCloud/provider placeholders, account transitions, progress identity and generated app test discovery remain separate gates.

The paired caller must preserve the captured account/container through its await, refresh metadata before recording completion, keep failed/unavailable attempts retryable, and use a new completion marker to recheck instances falsely marked complete by the old code. It must not erase the old marker or claim recovery of files already deleted by a previous release.

No production package requirements, root pins, persisted schemas, historical book keys, signing or CloudKit settings change here. No original user files are accessed by development or tests. Nothing merged to main.
