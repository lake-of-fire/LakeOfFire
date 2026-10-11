# Porting work: live Reader content annotation status

Source: Reader-selected Lake hotfix `10fdf15c8ce4550b4e7900830843c1c8f2ac9f98`.

Main currently exposes only `readerContentCellAnnotationStatusLoader`, so a mounted row reloads its note/task badges only when the row identity itself triggers another load. The hotfix adds an optional stream of complete per-row snapshots so note creation, task completion and deletion can update a visible row without installing a Realm observer in every cell.

This port adapts that contract to main's `LakeOfFireContentUI` split:
- optional `readerContentCellAnnotationStatusUpdates` environment provider;
- one view task owned by the row URL/content identity;
- stream snapshots are authoritative when a provider exists;
- the existing one-shot loader remains the fallback for hosts that install no stream;
- cancellation is checked before provider/loader work and before every publication.

The observation helper is generic over its Sendable snapshot solely to keep the portable contract independent of SwiftUI/Realm. Production uses `ReaderContentCellAnnotationStatus`.

The cell's existing display-state loading, menu behavior, sync status, Realm lookup and public API remain unchanged.

Qualification: a read-only macOS/Linux workflow runs six Debug and six Release Swift 6 observation cases with warnings as errors. macOS also frontend-parses the actual SwiftUI environment and cell integration. Full Lake target and host producer composition remain separate gates.

No schema, Realm observer policy, persisted annotation format, root Reader pin, signing or CloudKit change.

## October 11, 06:07 UTC reconciliation

Composed onto Lake #95 `67a76c535b1086828aeac4a304163a075517ec9a`, preserving its captured-Realm commands/observers, OPML test repairs and disabled-script convergence fix. ReaderContentCell.swift in that destination is byte-identical to this PR's original base, and the observation/provider/test files are absent. The exact three production blobs and six-test native fixture therefore remain relevant; the existing LakeOfFireTests target already directly depends on LakeOfFireContentUI.

Retired extracted-source Tools validation and its workflow are not restored. Their historical result remains above and in prior commits; no new tests or builds were run. Current paired adapter is Core #205 `160961df3c785274fa2e7f6e2f4f39b3f8963e86`; Core #206's host wiring must be reconciled separately. These stacks still require newer-audit composition and later owning-target/root qualification before Reader selection. No schema, package/root pins or production changes.


## October 11, 06:50 UTC current composition

Refreshed onto Lake #95 `7b6c4e63ed2c5fad34237b36c663c17a0ab4ae5c`, now including #74 `3216f9e13c3e7306ece6e842a48e0250c5268c6d` and #50 `7ba92a8cc3cdd9bc481931fb214856fc751394fe`. All three original live-consumer source blobs and the six-case test fixture remain identical; their destination paths are unchanged or absent relative to the prior #95 base. Newer import/storage/sparse-renderability/Library work is retained. No package pins or generated project changes.

The corrected paired Core #205 adapter is `2542b37733c14cb740d3ca6edf0ce6c58a6ceece` (canonical annotation identity), with #206 host `e891a871bd8ab1ea9b7afc98592cc1b2c33c7241` and newer #183 startup/import composition `9de0549edeaafc2523e5d22bf9228ede5736a219`. These replace the older candidate references above for this checkpoint; no Reader root selection is made. Tests/builds remain UNRUN. Actual mounted-row replacement/cancellation and complete native dependency qualification remain open.
