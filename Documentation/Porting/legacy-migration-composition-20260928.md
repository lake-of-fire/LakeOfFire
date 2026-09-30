# Porting integration: preservation-first legacy Documents migration

Compose #52 head `6bc57df28de7655ff08e2a21e392da64fcf69813` into current #50 `510890e68afc7b240eb13a9b5ae5910ff4674a0e`. Both are retained as direct parents. The six complete #52 files keep their exact blobs; all existing runtime, tests and production package requirements remain byte-identical. The only other addition is this record. Preserve the concurrent book-open owner/disappearance, collision-safe import storage, catalog and bound-native-restore work.

Core #183 at `12b140f820f37cac0a993d6e8293046099d5be6c` now calls ReaderLegacyDocumentsMigration from its actual existing startup migration method. That caller requires this composition (or equivalent selection of all paired APIs), not old Lake main. It no longer copies/deletes filename collisions or merges whole EPUB directories. Absent iCloud and failures do not set its new completion preference; cancellation/account/container are checked around metadata refresh. The old falsely-completed marker is preserved but no longer suppresses the repaired pass. The marker remains install-scoped, not a new account inventory.

Source #52 run36501707905 passed all28 real-filesystem cases in macOS Debug/Release, explicit Swift6 mode/warnings as errors, and typechecked the entire helper for iOS15 simulator. Both artifact logs, SHA-256 digests and complete executed source/test/manifest bytes were verified. Tests cover actual exclusive moves, collisions/recovery, packages/hidden children, types, links, reruns, cancellation and inode/metadata preservation. They are not actual iCloud/provider or complete Core startup tests.

Source branch evidence:
- Debug11005643022: 4e4871fdde89e3a77a3b19878c723fc66ddfb26dedb8e8c3c1f307ad39475884
- Release11004873001: aa810b8b6e99a021d34d6cb194c835283f452ae98725c9b6c9637f07347da752
- Helper c3b7ba9ff33a287eb080286ca9b06e30c8ddc79c
- Tests d6df7aae57ff0c209b62fbaf7eb19fcd00b82d30

The initial test fixture captured a non-Sendable owner in async-let argument evaluation; it was corrected to capture only the immutable URL. No runtime assertion was weakened or filtered. That failed compiler run is not a test pass or an additional product finding.

The prior #50 head510890e6 had all11 workflow groups completed successfully when inspected before this composition. That completion-status check is not a fresh detailed inspection of every retained artifact, and it is not automatically this new head's qualification. Inspect new committed-tree runs independently.

Remaining gates: actual iCloud/provider placeholders and identity changes, failed metadata refresh, recovered-directory discovery/progress attribution, real Core/Realm startup, full generated target/test discovery and signed two-client acceptance. Whole-item rename preserves bytes but changes paths; it cannot recover originals already deleted by old releases. File coordination protects cooperative participants, not every hostile-writer race or power loss. Top-level hidden container metadata remains outside scope, while hidden children of moved directories are retained.

No root pins, schemas, historical keys, original user books, main/v3-hotfix refs, signing or CloudKit settings changed. No source PR was merged to main. Full app qualification is still required; do not describe source-branch tests as a full composed Reader pass.
