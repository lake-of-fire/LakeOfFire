# Library independent source review

**Final rereview: both reported metadata defects are resolved in source.** Final LibraryFeedView blob `c190e27f4e183e46718c5648ce08f9a98df59cd3`; final editing tests blob `f3e08b1ddd2a477c8616ad73c3c77fa3611324cd` (supersedes reviewed `1e076d828ec43c434635e8bf33739271b7d10494` with the small gate correction below). Final corrections and their regression oracles were re-read below. No further source blocker found in this bounded rereview. Builds/tests remain not run by request. Initial findings are retained as review history, not current open findings.

Read-only review 2026-10-11 of current unstaged library candidate. No source edits, builds or tests. Shared HEAD at final capture `4041cfffec94af1eebb748608313909a4e943ec1`. Exact reviewed Git blob hashes (working file contents):

- LibraryFeedView.swift `25e378feb0e3869f78512bda4d1f01ad9b781860`
- LibraryConfiguration+Consolidation.swift `23637dcf5e67b76b4e786ff6debe118194e8ff2b`
- LibraryFeedEditingContinuationTests.swift `1480e0f5eb893b9310d1ce08fce1fdea26822c7b`
- LibraryConsolidationAdmissionContinuationTests.swift `e442c202b242326ab054e1320c40de8115c03397`

Both production diffs read completely, with full source slices for command admission, metadata request/refresh, finish/deinit, UI retirement and consolidation. All new tests read method-by-method; retained LibraryConfigurationConsolidationTests methods also inspected. Report applies to those exact blobs; later edits require follow-up review.

## Findings sent promptly to parent

**P1: late metadata command issuance can outrank a newer editor's deliberate empty input.** LibraryFeedMetadataAdmission is per model. Shared LibraryFeedWriteOrdering only sequences a command when it is created. Old editor A starts OpenGraph fetch with empty title; new editor B for the same storage/feed incarnation explicitly publishes empty title (a legitimate same-value/no-op input), reserving newer shared field order. A's fetch then resumes. A's private metadataAdmission still sees unchanged revisions/empty field. `applyMetadataValue` lines716–725 calls `writeFeedAsync`, which issues a *new* higher shared field sequence at line526. Persisted field is still empty, so A's metadata now wins despite B's newer intent. The same pattern applies to description and icon/URL intent across editors. Capture shared human-input revision at metadata request begin and require it remain unchanged at final write, instead of advancing metadata ahead of later human input. Keep synchronous no-op user reservations.

The new `testOlderWriterCannotBeatNewEditorsIntentionalNoOp` suspends a writer whose sequence was already issued before B's input. It meaningfully tests the existing final sequence guard, but cannot detect a metadata command created *after* B's input. A regression should suspend A's metadata fetch, publish B's empty input, resume A's fetch, and assert no automatic field value or pending mutation appears.

**P2: editor flush can replay canceled metadata work without its original cancellation.** `writeFeedAsync` places automatic metadata commands in `pendingFieldCommands` alongside user drafts. `finishEditing` lines501–504 calls `submit` for every pending command; `deinit` lines507–513 similarly calls `command.write()` again. Those replay tasks omit original `beforeWrite`/parent cancellation context. `applyMetadataValue` forwards cancellation only to its original returned task, not replay tasks. With a metadata writer suspended, `.task` cancellation plus view `.onDisappear { finishEditing() }` can submit another uncanceled copy. The request generation remains valid and final metadata guard checks only RSS/revisions/field emptiness, so the replay may persist after canceled request. Source identity guards correctly prevent writes to a replacement record, but do not revoke this still-current request. Separate buffered user draft flushes from active automatic tasks, or carry/revoke a shared cancellation capability checked by every command copy.

This is not a complaint about flushing user input on retirement: that behavior is desirable. The problem is replaying automatic work whose owning task was canceled. A regression should suspend metadata before final write, cancel it, invoke finishEditing, release the gate, and verify no metadata mutation. No existing new test covers this ordering.

## Behaviors retained correctly in inspected source

- Feed writes capture concrete Realm configuration, feed UUID/createdAt and category UUID/createdAt; resolve fresh objects inside asyncWrite; reject deleted/archived/OPML-managed category or replacement incarnation. They journal only when apply returns true.
- Shared ordering scope includes storage, encryption key, schema version and feed incarnation; weak registry entries do not become a permanent cache. Plain locks do not cross awaits. The ordering lock covers final apply/journal operation. No deadlock was demonstrated in inspected lock ordering.
- Buffered string input reserves shared order before debounce. Removing removeDuplicates permits intentional same-value reservations. Immediate toggle writes are field scoped. Hydration sets isRefreshing and preserves pending field drafts; it does not create writes.
- Paste reserves URL through the publisher and an immediate command, keeping captured storage. Preview entries resolve in captured configuration and reject feed incarnation replacement.
- MainActor metadata flow checks RSS URL, request generation, field revisions and user-editability, and final Realm command rechecks source/target eligibility. These provide meaningful single-editor protections; they do not resolve the two findings above.
- Consolidation selects survivor by createdAt/UUID inside one asyncWrite, preserves normalized existing primary order, collects new relationship candidates by immutable target createdAt/UUID (or missing-record source config createdAt/UUID/ordinal), excludes deleted/archived resolved targets, admits active orphans, deduplicates, and tombstones duplicates in the same transaction. Main primary and duplicate metadata updates use one timestamp. No managed object from pre-await selection is reused. Repeat no-op does not journal primary.
- Unresolved existing IDs are preserved; missing incoming target IDs are admitted with deterministic source keys. Later target arrival intentionally leaves already-admitted primary placement intact. This review does not claim CloudKit delivery-order convergence beyond that specified policy.

## Test source reviewed and limits

New editing suite, all7 methods:

| Method | Actual oracle |
| --- | --- |
| DelayedFieldWriteKeepsCapturedStorageAfterDefaultReplacement | Holds beforeWrite; switches process default; asserts original storage edit and zero replacement journal. |
| OlderWriterCannotBeatNewEditorsIntentionalNoOp | Already-issued older title writer loses to synchronous same-value publisher reservations from another editor. Does not cover late metadata issuance. |
| DelayedWriterRejectsReplacementFeedIncarnation | Replaces UUID record with changed createdAt; checks replacement unchanged, zero journal, preview nil. |
| DelayedWriterRejectsManagedOrReplacedCategory | Both OPML promotion and changed category incarnation reject pending write. |
| DelayedMetadataCannotFillAfterSourceURLChanges | Suspends OG fetch, pastes new RSS URL, resumes; asserts title/description untouched and new source kept. |
| MetadataCannotReplaceAnExplicitEmptyDescriptionEdit | Suspends metadata final write, publishes empty description on same editor; asserts no automatic description and draft remains empty. Does not cancel/flush or use a second editor. |
| HydrationDoesNotPublishNewMutations | Refreshes and finishes model; no-op writer drain; journal remains empty. |

New consolidation test loops two Realm configurations with reversed incoming category/script order and opposite category modifiedAt values. Existing primary category placement survives; new targets sort by immutable createdAt; duplicates tombstone; second consolidation leaves mutation generations unchanged. This is a real Realm behavior oracle, not source-string matching.

Retained consolidation methods inspected: duplicate relationships across configurations; unchanged primary journal avoidance; existing placement plus incoming deduplication; existing duplicate repair; missing-record references; active orphan scripts/categories with createdAt/UUID ties and archived exclusions; standalone legacy merge helper placement; survivor independent of modifiedAt; equal-createdAt UUID tie break. The legacy merge helper remains directly tested but is no longer the production consolidation ordering algorithm. Its tests must not be cited as evidence that incoming duplicate relative placement is preserved by the new algorithm.

Missing new oracles: late metadata fetch across editors; canceled metadata plus retirement replay; icon generation/cancellation counterpart; real mounted editor same-feed storage/identity replacement; invalidated Feed SwiftUI identity access; consolidation unresolved-candidate ordering/ties and deleted-candidate admission changed while transaction waits.

## Compile/runtime boundary

Package declares Swift tools6.2 and Xcode Swift6. MainActor model owns UI publishers, requests and hydration. Realm command closure is explicitly @RealmBackgroundActor @Sendable and carries IDs/configuration/plain lock state. SwiftUI actor inference and class deinit crossing global-actor-isolated NotificationToken storage require compiler verification; the token deinit pattern predates this change, and this review found no proven new diagnostic. No build/test or native runtime was used; absence of additional source findings is not a compilation or mounted UI claim.

## Final correction rereview

Final source adds shared-intent `snapshot()` and locked `withMetadataAdmission(field:expected:apply:)`. `beginMetadataRefresh` captures shared field intent map at request start. `LibraryFeedFieldCommand.write` selects this branch for metadata, checking both target-field intent and URL intent while holding the shared ordering lock through apply/journal. It does not issue another human-input sequence. P1's late OG result therefore fails final admission after another editor's deliberate empty publication, including same-value no-op input. Existing per-editor generation/revision, RSS and record-incarnation checks remain intact.

Final `applyMetadataValue` creates a dedicated command with request's shared intent snapshot, then one cancellable RealmBackgroundActor task. It does not call writeFeedAsync and does not insert that command into pendingFieldCommands. finishEditing/deinit therefore flush only the user-command queue; they cannot replay this automatic metadata command. Cancellation handler cancels the sole write task, and command checks cancellation before and inside asyncWrite. P2 is resolved while preserving user-draft retirement.

Both added tests read entirely:

- `testLateMetadataCannotOutrankAnotherEditorsEmptyInput`: suspends old editor OG fetch before command creation; constructs another same-feed editor, publishes empty title, finishes/drains no-op writer, then releases old fetch. Actual title and journal must remain empty. This reaches the previously uncovered late issuance ordering.
- `testRetirementDoesNotReplayCancelledMetadata`: suspends metadata before write, cancels parent metadata task, calls finishEditing and drains another user no-op write before releasing metadata gate. Actual description must remain nil and journal empty. This reaches the previously uncovered canceled-task/retirement ordering.

No source-string assertions or validation tooling added. These tests are runtime regression source; they were not executed. The late-result test may permit subsequent fallback OG fetch attempts, but every attempt uses the original captured shared intent and fails admission, preserving the oracle. Icon follows the same dedicated applyMetadataValue path; a separate icon regression remains optional coverage, not a new source blocker.

Consolidation source and its new test are unchanged from initial reviewed blobs `23637dcf5e67b76b4e786ff6debe118194e8ff2b` and `e442c202b242326ab054e1320c40de8115c03397`. Remaining mounted/native compile and broader convergence limitations above remain unverified; the two concrete source findings are closed.

Final six-line test-only diff reread: late-metadata test now passes expectation fulfillment as `gate.wait(onFirstWait:)`; gate invokes it only after `guard !released`. Sequential fallback OG requests after release therefore return immediately without fulfilling the expectation again. Callback and continuation installation run on the gate actor without an intervening suspension, so the initial-wait oracle still fires before gate release can resume it. Other tests use the default nil callback and retain their prior behavior. No source regression found in this correction; no tests run.
