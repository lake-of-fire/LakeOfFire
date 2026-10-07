# Original deletion admission — October 6, 2026

## Reviewed source and findings

Lake #109 originally selected `62fe80ebb16c46e4177b5fcb9a8d179be257c58b` over #107. Reader #303 has since merged into the #286 development lineage; those earlier storage fixes are not an outstanding reimplementation task.

The adjacent deletion executor still retained only its selected drive through asynchronous availability and directory inspection. The captured Realm was used later, but neither a replaced Realm nor a newer initialization was part of the pre-removal/final-write predicates. A cancelled/replaced initialization can leave the same installed drive object, so drive identity alone is insufficient.

The repair reuses `MetadataRefreshSelection`, captures it before the first suspension and requires it at every existing deletion fence. The shared nonthrowing predicate also fences optional list cleanup. Metadata and package tombstones remain in the same existing owned Realm transaction, with one shared mutation timestamp and no-op behavior unchanged. The original selected drive alone participates in destructive admission: changing an unrelated cloud drive does not revoke a current local deletion. Optional full inventory refresh retains the original complete tuple and may decline an obsolete publication.

An additional cleanup closes an ignored throwing Task in that optional refresh. Cancellation of optional publication is ignored; other refresh errors are logged. Neither changes a deletion which already committed into a reported failure. Filesystem removal and Realm indexing are still separate phases; this does not make them one atomic transaction or undo an already-finished physical removal.

No new schema, queue, actor, lock, ownership framework or public entry point is introduced. Existing read/import/publication fixes are retained.

## Exact executed evidence

Production and native tests published at `074e423dc414112196187b7a3389c6ad77377637`:

- before manager blob: `1bc5217c7130b083bcea76ccf96f1475362890ac`
- revised manager blob: `21cebbda77c3973e6aabd7fd4527b0587a29fe7e`
- before native owner file: `1e947f1c689d3cf303c6a09ba7945389161b9bd5`
- revised native owner file: `ce5cb0481b129ffd5588c01d8735b5bfc6f0c8a7`
- executable control driver: `1b67929f0cae09725ce0933e54dbb8bad1b367c4`

Both local Swift 6.2.1 and hosted Swift 6.4 ran the same **19 distinct histories** on Linux:

| Source | Passed | Failed | Process exit |
| --- | ---: | ---: | ---: |
| Original executor/validators | 9 | 10 | 1 |
| Revised, Debug | 19 | 0 | 0 |
| Revised, optimized | 19 | 0 | 0 |

The original failures are the Realm/initialization variants at status, directory and index boundaries, including missing-file histories. The successful controls retain current admission, unrelated-drive changes, caller cancellation and post-commit truth. Repeated configurations/compiler versions are not additional unique histories.

These controls compile complete production deletion executor and selection-validator declarations. Availability, Realm/index commit, drive coordination and publication collaborators are explicit doubles. File creation/removal uses real task-owned temporary files. In particular, the simulated index assertions are NOT actual Realm/journal acceptance. No full manager typecheck or Apple runtime result is implied. The full production and actual native test files were separately frontend-parsed only.

The revised declaration controls compile with Swift 6 complete concurrency and warnings as errors. The original uses permissive warnings on Swift 6.4 because its ignored throwing Task triggers the compiler diagnostic. The first hosted attempt (`37416500037`) stopped on that warning before any control executed; it is retained as a zero-execution compile failure, not a negative-control pass.

Passing hosted run: `37416875718`. Artifact `11391396256`, SHA-256 `f4a38453f3cc1567ff2f3386d00289ac9fb038033912929ae3edd158f98061a2`. The complete artifact was downloaded, its digest checked, its per-history records reconciled with process receipts, and both revised full source/test files compared byte-for-byte with local execution inputs. The prior failed artifact is retained at `11391535632`, SHA-256 `7ad1b2be2b625f8e30d5169418eb6c721080383a9026292ab82e40dd51f832cf`.

A temporary branch-restricted delivery workflow applied the reviewed, full-blob-guarded delta and used a normal fast-forward push to this PR branch only. That helper and its write-permission workflow are removed in the documentation successor. The retained workflow is read-only and runs the declaration controls; it grants no native or release qualification.

## Native requirements and remaining limits

The complete previous 34-method native owner file is an unchanged byte prefix. Six additions bring `ReaderFileLibraryBoundaryTests` to **40 methods**:

- `testDeleteRejectsRealmReplacementBeforeRemovingPayload`
- `testMissingDeleteRejectsRealmReplacementBeforeTombstoning`
- `testDeleteRejectsFailedNewInitializationBeforeRemovingPayload`
- `testMissingDeleteRejectsFailedNewInitializationBeforeTombstoning`
- `testAlreadyCancelledInitializationLeavesCurrentDeleteAdmitted`
- `testLocalDeleteIgnoresReplacementOfUnselectedCloudDrive`

These use the real manager, local filesystem, captured Realm and journal. They are authored and syntax-checked, not Apple-typechecked/discovered/executed by this review. They extend the existing registered file, so no new source path is required. The Reader follow-up must union the six identities into both required inventories and select the final preserving Lake head.

Keep prior native/Core JavaScript/CloudKit evidence source-bound. Current Apple acceptance, runtime linkage diagnosis and the newer compatibility bridge remain independent. Mac UI/signed/performance/application Release are owner-deferred. Authentic released paired Realm provenance and genuine second-account evidence remain unavailable. No production Realm/CloudKit data, account or user file was mutated; no target branch merge or release authorization.
