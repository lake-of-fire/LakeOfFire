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
