# Forced inventory replay reassessment — October 2, 2026

## Baseline and disposition

Reader #187 and #280 have landed into `v3-hotfix`; they are not still waiting for the September 30 root composition. Inspected Reader target: `6fcd387fb3387d10662a380fff8c371404a23a6e`, selecting Lake `45afff5a9009ad6cc75b02493be787dda846f035`. The previous Lake #84 head `16a50013afaa5ec284fd4357ad87817426a2d90a` is an ancestor of that selected Lake revision, including the real-queue test correction that avoids calling a fileprivate completion method.

This follow-up is based on current Lake `v3-hotfix` `ab1670f03320ddd7e1e485305a6b033a915d9a9a`, preserving the subsequent #102 OPML qualification work. The affected queue and existing test file have exactly the same original blobs at this target and Reader's selected Lake revision.

The fresh review examined the current inventory queue and complete tests, its ReaderFileManager lifecycle/cancellation entry points, OPML preparation/cleanup ownership, current native pending-ledger and JavaScript terminal-delivery boundaries, and live root/component integration records. It is not an exhaustive audit or qualification of all dependencies.

## P2 finding: replay discarded an outstanding forced admission

Ordinary `enqueue` coalescing retains `oldForce || newForce`. The cancellation replay in `drain` did not: when an interrupted in-flight request found a newer pending request for the same storage scope, it appended the old completion owners but discarded the old request's force flag.

A concrete history is:

1. A forced inventory refresh begins.
2. Application suspension cancels its driver, without settling the logical refresh request.
3. A newer ordinary notification supplies the replacement snapshot for that same scope.
4. The cancelled driver transfers its completion owners to the replacement and joins.
5. Resumption incorrectly treats the outstanding forced caller as ordinary work: it can be throttled or placed after unrelated ordinary storage work.

The regression clock records an incorrect two-second throttle with the existing default interval. This is controlled scheduling evidence, not a performance benchmark or attribution of a historical visible-latency incident. No new persistence/data-loss defect is claimed.

## Correction

At that existing replay/coalescing boundary, union `pending[index].force` with `inFlight.force` before transferring the completion owners. The most recent snapshot operation still wins. No new queue, actor, task, lock, retry loop, storage identity, or public API is introduced.

Preserved: independent waiter cancellation; shared producer lifetime; cancellation-to-resume replay; per-scope coalescing; normal throttle behavior; latest producer success/error delivery; force ending when that logical request settles. Realm writes, orphan detection, OPML and CloudKit behavior are unchanged.

## Behavioral coverage

The entire pre-existing 22-method test file is retained as an exact byte prefix. Four methods are appended to the same `ReaderFileRefreshQueueTests` class in its existing source file:

- `testSuspendedForcedRefreshDoesNotAcquireSuccessorThrottle`
- `testResumedForcedRefreshKeepsPriorityOverOrdinaryOtherScope`
- `testReplayUnionPreservesForceAndLatestOutcomeAcrossAdmissionCombinations`
- `testRepeatedSuspensionKeepsOriginalForceAndAllCompletionOwners`

The combination test exercises all 16 old/new-force, success/failure, and resume-before/after-join combinations. It checks both original and replacement completion results, recovery after failure, and ordinary throttling after the forced request has completed. Repeated-suspension coverage retains all three completion owners. Tests use the production queue through its existing interfaces and controlled clock/sleeper inputs, not a source-text assertion or replacement queue model.

## Executed local evidence

Linux x86_64; Swift 6.2.1; Swift 6 package language mode; warnings-as-errors. The isolated package compiles the complete production `ReaderFileRefreshQueue.swift` and complete `ReaderFileRefreshQueueTests.swift` under their normal module names, without Apple framework stand-ins.

| Exact run | Methods | Passed | Failed methods | Assertion failures | Skipped | Exit |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Final inventory against original queue | 26 | 22 | 4 | 11 | 0 | 1 |
| Final inventory against fixed queue, Debug | 26 | 26 | 0 | 0 | 0 | 0 |
| Final inventory against fixed queue, optimized Release | 26 | 26 | 0 | 0 | 0 | 0 |

The 11 XCTest failures in the negative control are assertions across four failed methods, not 11 failed tests. The 22 original methods pass on both implementations. The trailing Swift Testing message with zero tests is a separate unused runner; the named XCTest executions above are the behavioral evidence.

### Exact Git input blobs

| Input | Git blob SHA-1 |
| --- | --- |
| Original production queue | `09c9cb1be54e65ed3970083a6890a8a033b6f8f5` |
| Fixed production queue | `c6cb05a58ec257e6a8428c88e62c34f6d43e3bff` |
| Original complete test file | `54a84284d1d51a804e3c1b8db48cd61200096276` |
| Final complete test file | `f53f7e9488ba902000306c0f170b6684bf1f595a` |

Publication was checked against the executed blobs. An intermediate upload omitted two statements from an existing throttle test; that staging mismatch was corrected before this PR's final evidence attribution. No result is attributed to the mismatching intermediate blob `f00617be8de61e6afc6615115df94753f7a31a54`. Final code/test commit: `f29adef75cd571d01be1b674aa866acc30a39a8d`.

### Retained local log SHA-256

- `full-before.log`: `ec029dec7be0bd6470a1f2af26b5bd6c2cc25ef9957b5e89d44b9646fc3d3aac`
- `full-final-debug.log`: `b3bb657ebf6febaca167dbfcdee22f1100852098ba6eadb87569ddabe067fc12`
- `full-final-release.log`: `2f7e48950fb03e84f1141bfb10dd3435de64add7535d6a28e975573bc913e206`

These hashes identify local execution logs, not uploaded xcresults or independently retained native evidence. CI results, when available, must be cited with their actual workflow/commit identity instead of inferred from these local runs.

## Reproduce

The existing `Reader inventory refresh queue` PR workflow compiles these same two complete files. Locally, copy them to an isolated package with targets `LakeOfFireContent` and `LakeOfFireTests`, Swift tools version 6.0, then run:

```sh
swift test -Xswiftc -warnings-as-errors
swift test -c release -Xswiftc -warnings-as-errors
```

For the negative control, keep the final tests unchanged and substitute the complete original queue from `ab1670f03320ddd7e1e485305a6b033a915d9a9a`. Use separate log/status filenames for each run. No released Realm files, accounts, or original user content are needed.

## Integration and remaining qualification

The four added methods are in the already registered owner file; no new Tuist source path is introduced. Reader still needs to select this component successor, reconcile the two source/test fingerprints in its current ledger without regressing other pins, and execute the complete queue class plus affected inventory/import/lifecycle callers on the resulting Apple graph. This PR does not move Reader's gitlink or authorize an assembled pass.

Optimized Linux component execution is not application Release. No native Apple, WebKit UI, Mac UI, signed CloudKit, performance, migration, account-switch, or release run was performed for this successor. The existing authentic released-Realm/second-account and owner-deferred release gates remain separate. Do not reopen the superseded #301/#84/#252 source fixes merely because their old descriptions retain historical pending language.
