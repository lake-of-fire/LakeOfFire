# Legacy migration: verified inputs and native results

The combined tree at d7ef62d9f0c98cb5fff64d8d0c6baf7f1e2c5e00 adds the six exact files from #52 plus its composition record to prior #50 head510890e68afc7b240eb13a9b5ae5910ff4674a0e. Complete comparison: seven additions, no modified/deleted pre-existing files. This documentation-only descendant does not change production or tests.

The actual Core #183 startup caller is 12b140f820f37cac0a993d6e8293046099d5be6c. It requires the migration API in this branch, as well as the earlier shared-import/native-restore APIs. Source-only helper selection against old Lake main is not a full compatible consumer tuple.

## Verified source-branch execution

Run36501707905 tested merge4d92d1437e1715f7e50cc3d5cded89bbae61fcd6 of source #52 head6bc57df28de7655ff08e2a21e392da64fcf69813. Both macOS arm64 Debug and Release logs show28 named XCTest passes, zero failures. Swift6.2.1, explicit Swift6 mode and warnings as errors. Both jobs also pass full-helper typechecking for iOS15 simulator; no interactive simulator/iCloud result follows.

Artifacts downloaded and verified:
- Debug11005643022 SHA256 4e4871fdde89e3a77a3b19878c723fc66ddfb26dedb8e8c3c1f307ad39475884
- Release11004873001 SHA256 aa810b8b6e99a021d34d6cb194c835283f452ae98725c9b6c9637f07347da752

Complete executed files:
- Production c3b7ba9ff33a287eb080286ca9b06e30c8ddc79c
- Tests d6df7aae57ff0c209b62fbaf7eb19fcd00b82d30
- Component manifest4d9b546b95f93b3a1f74ae4010b3c54c8232069b

All bytes match local sources and the tested Git manifests. The tests exercise actual filesystem moves, not a copy/remove or mock-drive implementation. Repeated configurations are not56 unique tests. The first failed test compilation was corrected by capturing only the immutable root URL; no unchecked Sendable, filtered method or weakened expectation was used.

## Not established by this evidence

These source-branch tests are not automatically current integration-head execution. At this record's creation the new branch ref was verified, but PR metadata/workflow listing had not yet reported new-head runs. Record actual completed results separately; do not infer green CI from source passes.

The complete private Core/Lake/Reader startup graph, real provider placeholders, account transitions, metadata failure, recovered-path progress attribution, full Tuist discovery and signed CloudKit acceptance remain unqualified. The new completion preference is install-scoped and cannot restore files already deleted by older migrations. Whole directories are intentionally preserved as siblings instead of merged; root hidden metadata remains excluded, hidden children retained. No user files were touched by development.
