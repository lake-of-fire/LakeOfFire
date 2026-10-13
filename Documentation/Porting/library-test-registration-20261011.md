# Remaining Library test registration — 2026-10-11

Source-list audit compared Reader #384 `88e200ce8c859c0ffa52b6855c910f7e39cc67ef` against Lake #138 `bd663215d456c58ecb36a2ee879218cbcb55d7a8`. Eight Library regression source files existed in the package but were absent from the root's explicit Tuist test list. They contain 58 methods by source count. Registration is tracked in the root's lake-native-test-registration document; it is not generated discovery or passing evidence.

Reviewed their direct imports and fixture-support references. Root must explicitly include OPML and LakeOfFireCore in addition to already-registered LakeOfFireLibrary, Content, RealmSwift/Gaps and BigSyncKit. MutationTrackingTestSupport is already listed. No generation or compilation occurred.

Also made the prepared-export captured-Realm fixture self-contained: it now creates a named in-memory Realm with the six Library model types and the shared test mutation configuration instead of copying the process's DefaultRealmConfiguration. This avoids inheriting unrelated application schema/storage settings into an ostensibly isolated fixture. Existing test behavior and count are unchanged.

All tests remain UNCOMPILED/UNRUN. Further actor/runtime isolation qualification remains necessary under the existing native-test hold. No builds, tests, benchmarks, native launches, CI, dependency pins, merge, closure or deployment.
