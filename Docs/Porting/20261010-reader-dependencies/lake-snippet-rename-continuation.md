# Focused snippet rename continuation — 2026-10-11

## Scope and frozen provenance

Candidate begins at owned draft [#138](https://github.com/lake-of-fire/LakeOfFire/pull/138) head `338acd87`; selection owner commit `5823a902` is preserved. Main target remains `8985bf92b9504d53e00025e4054b3aa97f876e45`. Selected hotfix remains `036d4193078016db0becdf91b86dd34fb1d579e0`; separately refreshed in-window remote endpoint is `6e492b3e2a65b4d8a7e49a0e196152d82b6bdc04` (2026-10-10 20:18:03 -04:00, merge #137). Only title-owner/writer and seven narrowly scoped runtime test methods were authored. No ReaderContentProtocol, Files, Core, root or Library edits by this worker.

Source behavior provenance: `2f6e08e0bca0c4303b1b4dbc7ac16fd02e3e53b4` (2026-09-07) adds durable explicit target title command and current persisted HTML authority. Selected pin additionally contains `c8efdccfa7ad43393da56839b6a4ac97e02d19ea` and `e13a0472208d72dfc37671dd63f86ce16d68e03b` (2026-10-02) captured storage, commit gates and same-Realm atomic representations. Remote endpoint ReaderContent includes invalidation guards from `cf64f5eb326b6ad56e2d4f6528c586253abcd7d6` (2026-10-09). These later storage contracts are distinct from the focused URL-only command port.

## Pending head comparison

Every relevant pending owner/writer source was inspected at its fetched SHA for explicit-title and writer declarations. All upstream heads lack both; hotfix-base heads are not evidence of main integration.

| PR | SHA | Base | Title command classification |
| --- | --- | --- | --- |
| [#137](https://github.com/lake-of-fire/LakeOfFire/pull/137) | `8b9d8381ce7561625452545b99260b29aaf81f37` | `v3-hotfix` | Hotfix-only; title writer exists, not upstream acceptance |
| [#113](https://github.com/lake-of-fire/LakeOfFire/pull/113) | `9ef23abaecf93eb24dfbe55cbf02e9598f4f935f` | `v3-hotfix` | Hotfix-only; title writer exists, not upstream acceptance |
| [#95](https://github.com/lake-of-fire/LakeOfFire/pull/95) | `21c42ff0138c0b5b934956cbcccd107e5c577cf6` | `main` | No updateSnippetTitle writer or explicit-title overload; missing |
| [#74](https://github.com/lake-of-fire/LakeOfFire/pull/74) | `ad19065bd567f09f64a7f321feb2087fd60701fa` | `port/epub-serving-safety-integration-20260928` | No updateSnippetTitle writer or explicit-title overload; missing |
| [#61](https://github.com/lake-of-fire/LakeOfFire/pull/61) | `0dc1e429fc8e2d2b7e7f2a176fe2f72fabc7ab9e` | `port/epub-serving-safety-integration-20260928` | No updateSnippetTitle writer or explicit-title overload; missing |
| [#59](https://github.com/lake-of-fire/LakeOfFire/pull/59) | `0dd0b07afac69c6d02512a7b02ff2acb27bf7bb0` | `port/epub-serving-safety-integration-20260928` | No updateSnippetTitle writer or explicit-title overload; missing |
| [#54](https://github.com/lake-of-fire/LakeOfFire/pull/54) | `28c6911ada2221bc9a390de65f31b79bfba84bd4` | `main` | No updateSnippetTitle writer or explicit-title overload; missing |
| [#53](https://github.com/lake-of-fire/LakeOfFire/pull/53) | `35e0a7e65ce63365a9923a92fac832ad087c549b` | `main` | No updateSnippetTitle writer or explicit-title overload; missing |
| [#51](https://github.com/lake-of-fire/LakeOfFire/pull/51) | `547b1e88a836c8c4b53c24c98294700e9066a745` | `main` | No updateSnippetTitle writer or explicit-title overload; missing |
| [#50](https://github.com/lake-of-fire/LakeOfFire/pull/50) | `0b91431f0fe04c45b24b08b427a5df66e87661b9` | `main` | No updateSnippetTitle writer or explicit-title overload; missing |
| [#48](https://github.com/lake-of-fire/LakeOfFire/pull/48) | `2f3a63733583e179bddc8025a7320141fc1ddade` | `main` | No updateSnippetTitle writer or explicit-title overload; missing |
| [#41](https://github.com/lake-of-fire/LakeOfFire/pull/41) | `af14b895d9d3e1a1fe8c3a00e52c158d6eae211e` | `main` | No updateSnippetTitle writer or explicit-title overload; missing |

## Authored source behavior

- `Sources/LakeOfFireContent/Reader/ReaderContentLoader.swift:1365`, `updateSnippetTitle(contentURL:title:)`: **focused missing port authored, runtime unverified**. Trims input, rejects non-snippet/empty input, uses existing `@RealmBackgroundActor updateContent` write boundary, computes prefix from each persisted object's HTML inside its write closure, rejects invalidated/deleted objects, mutates only changed title/prefix, and relies on that same existing writer for explicit metadata/journal refresh. Same title with stale prefix metadata is a real change; identical title/prefix does not refresh metadata. Does not overwrite HTML.
- `Sources/LakeOfFireContent/Reader/ReaderContent.swift:380`, new `updateContentTitle(_:for:) async throws -> Bool`: **focused missing port authored, runtime unverified**. Required explicit URL avoids changing overload resolution for legacy callers. Captures currently displayed object/selection/reference, awaits durable writer before publishing any requested title fields, then admits refresh only for same captured object, persistent selection and matching page. Rechecks these after awaited main Realm resolution; rejects invalidated/deleted refreshed rows and rechecks the resolved/captured URL. Explicit callers can observe errors and Boolean changes.
- Same file `:413`, existing `updateContentTitle(_:) async`: **compatibility retained, snippet behavior corrected**. Signature remains nonthrowing. Captures current snippet URL at invocation and delegates to durable command without the old equal-title early return; logs errors. Existing non-snippet title path remains outside this focused port and still uses its older eager behavior. The compatibility wrapper cannot fix a modal whose URL was never captured when opened.
- Existing selection load/getContent code, static resolver API/navigation-task tokens, feed/history authority guards: **retained unchanged by this tranche**.

## Exact cross-boundary caller/API tuple

Historical selected-root evidence: production callers were traced from upstream Reader root `3c10696d33c294e6657945d66353212ce4b76c43`, selecting Core `c4b86d15a42e8db174c95fac20b1561f50797a13` and RealmSwiftGaps `ffb9b50248291b7f13d6df42a27d8f1383ca618e`. Fresh Core main evidence is `d50a8c2cc66f341bb0a15cbbec3958cef0c1a3d6`, read from task-root `core-api-snapshot-d50a8c2c.txt`: SnippetAppendBar presentRename remains at 238, captures only title text and invokes legacy nonthrowing method at 245; LookupsSnippetReaderView debounce remains at 512 and invokes that same method at 515. Thus the caller gaps below persist at fresh Core main; c4b86 is historical provenance rather than a claim to current main. This fresh read covers only the exact snapshot ranges, not all Core source or storage/dependency APIs.

1. Core `Sources/ManabiReaderCoreReader/Reader/SnippetAppendBar.swift:238`, `presentRename`: seeds UI from content.title, but completion currently captures only new text/reader and creates Task calling legacy updateContentTitle. A modal opened for A, followed by navigation to B, renames B. Parent boundary: capture snippet URL at modal open, pass `try await readerContent.updateContentTitle(newTitle, for: capturedURL)`, handle thrown persistence/refresh failure visibly. URL-only adaptation fixes document targeting but **does not fix storage/account replacement**.
2. Core `Sources/ManabiReaderCoreReader/RootNavigation/Navigation/Tabs/Lookups/LookupsSnippetReaderView.swift:512`: debounce callback checks current content.title then creates Task invoking legacy title command. Parent boundary: tie editable draft to URL captured at edit initiation, carry the same URL through debounce completion and cancel/reject superseded draft generation. Calling new overload with current URL only when debounce fires is insufficient.
3. Full delayed-command tuple must eventually capture `(snippetURL, original storage configuration/ownership, editor/modal intent generation, commit admission)` at originating intent; use source `SnippetStorage(content:)` / captured fallback where appropriate and check admission after Realm waits and inside/final write transaction. Main has no `SnippetStorage`, `updateCapturedSnippetRecords` or `asyncWritePreservingOwnership` at the selected RealmSwiftGaps dependency. No public storage token, fake account fencing, alternate transaction ownership primitive or captured-account claim was invented here. That API/parent dependency integration remains **missing**.
4. Explicit command result is Bool changed or thrown error; false means rejected empty/non-snippet input, identical metadata, or no stored match under existing writer semantics. Separate Realm writes may partly commit before a later failure. A refresh error can occur after durable title commit: caller must not interpret every thrown error as total rollback. Existing global configuration/loadAll writer is not atomic across stores or all duplicate representations and can select only existing loader matches.

## Runtime regression source (not run by request)

New `Tests/LakeOfFireTests/ReaderSnippetRenameCommandTests.swift` has seven production-owner/Realm methods; ordinary test target discovery unchanged. Four managed/frozen/target fixtures adapt selected hotfix title tests to main's required explicit-target overload. Configurations use existing mutation tracking helper and temporary test Realm; no user Realm is opened.

| Test line | Runtime invariant authored |
| --- | --- |
| 69 | Managed title persists, requested whitespace trims, HTML stays exact; journal generation changes only for real mutation; repeated/empty inputs preserve generation/timestamp. |
| 112 | Frozen displayed snapshot refreshes after durable write; frozen object stays unchanged. |
| 133 | Rename after persisted body changed uses current stored HTML rather than frozen display HTML for generated-prefix flag. |
| 168 | Explicit A target while B displayed persists A and preserves B object/title/chrome. |
| 195 | Legacy same-title command repairs prefix metadata; old UI title comparison must not skip it. |
| 213 | Throwing production additional provider during persistence lookup surfaces explicit-command error without publishing requested title/prefix/chrome or advancing modified timestamp. This exercises pre-write lookup failure, **not a forced commit failure**. |
| 266 | Production provider gate suspends A rename; preloaded selection changes display to B before writer completes; A durable update does not refresh/adopt B. Real selection owner and writer used. |

Missing runtime oracles: failed commit/partial-store outcome, captured storage/account replacement, final-admission rollback, all duplicate/live alias representations, concurrent rename ordering, invalidation during refresh, same-object ABA rename refresh after a full navigation round-trip, Core modal/debounce UI handling. Existing loader cache/provider/global configuration isolation remains the runner's concern; tests were not compiled or executed.

## Deterministic and recorded shuffle coverage

Deterministic review followed writer → public title owner → Core modal/debounce → selected/remote storage boundary → focused runtime fixtures. Supplementary source re-read used Python `random.Random(20261011).shuffle` over the finite cluster list; order:
1. ReaderContent explicit-target publication
2. Managed/frozen rename runtime fixtures
3. ReaderContentLoader persisted-prefix mutation
4. Storage helper/transaction admission boundary
5. Core modal captured target
6. Core debounced editable title

The shuffle revisited only these inspected behaviors and does not close broader files. All six clusters have classifications above; no further inventory closure claim.

## Verification and remaining limits

Tracked owned-source `git diff --check` has no diagnostics. New-test `git diff --no-index --check /dev/null ...` also has no whitespace diagnostics (exit 1 denotes the added-file diff). No tests/builds/generators/native apps/install/CI dispatch, stage/commit/push ran by this worker. The report is task-root only; shared repository reports belong to parent.

This completes authoring the narrow URL-target durable snippet rename port. Captured storage/admission and Core caller integration remain **partially/incorrectly ported or genuinely missing**, as described above. Broader snippet append/editor writes, title concurrency, storage lifecycle, Realm transaction helper, non-snippet title writes and earlier audit inventory remain unreviewed/open. No runtime-verified, root-integrated or full title lifecycle closure claim.
