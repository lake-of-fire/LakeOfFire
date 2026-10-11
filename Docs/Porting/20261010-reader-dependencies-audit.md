# Reader dependency forward-port audit — 2026-10-10 boundary

## Local replacement review — October 10, 2026 (America/Toronto)

### Hotfix port: script field input and editor retirement — October 11, 2026

This continuation starts at candidate `74154572c5c31e85cc38eaec0a4bc99c4b2cf07b`.
Hotfix `3d9791093686f75aeb2e091d3c9a06c44d7bb9cf` captures script field input and
editor identity; `6c61199059dcc2f828e60b745399ef189442bff9` adds retirement flushing
and shared input ordering. Both are retained in inspected Lake hotfix endpoint
`64f65fbb39238d126700ab3f9d4df59fd76a701c`. Pending #95 `21c42ff0` retains the old
script-field model, so this adaptation adds no competing pending implementation.

`LibraryScriptFieldCommands.swift` captures the actual script Realm configuration, UUID,
createdAt and field intent synchronously at input, before debounce. Its final background
transaction resolves the live row and rejects deleted, externally managed or recreated
owners. Transient ordering is shared across editors and pending commands for the same
storage/incarnation and scoped independently per field. A newer intentional no-op retires
older input before either write commits; no-op field assignments never refresh metadata
or advance the journal. Every admitted mutation refreshes explicit metadata in the same
transaction. Entry, post-suspension and final-transaction cancellation checks retain retryable
drafts in a live editor without applying cancelled commands.

`LibraryScriptFormSectionsViewModel` suppresses hydration publishers, retains pending
drafts during refresh, flushes before script replacement and on disappearance/release,
and settles only the matching intent. Explicit writes and paste publish the captured draft
through that same path. A failed write remains pending for `finishEditing()` to retry;
throwing tasks are observed through `# LIBRARYSCRIPTEDITOR`. Object observation uses
Combine on the live object's MainActor and rotates a callback identity on replacement.
The form's StateObjects receive the captured storage configuration and its SwiftUI identity
includes storage and incarnation. Main's modular/domain-cell composition is preserved.

Fourteen new runtime regression methods are authored in
`LibraryScriptFieldOwnershipTests.swift`: captured storage after default replacement;
buffered title/text/preview replacement flushing; old completion versus replacement draft;
all seven fields, repeated no-op journaling and preview clearing; hydration without intent
reservation/journaling; reopened-editor no-op before its commit; four final-writer retirement
cases; published unchanged input before debounce; injected failure plus retry; suspended
cancellation plus retry; paste superseding buffered input across replacement; model release
and final draft flush; independent fields; live observer replacement and physical deletion.
Fixtures use private in-memory Realms and RealmBackgroundActor for all mutations. Both new
source directories belong to existing package targets with the required direct dependencies.
These sources are uncompiled/unrun; no test discovery, builds, native launch, generators,
package resolution, benchmarks or CI ran. Validation is source/API/history inspection and
`git diff --check` only.

This is a published-candidate source adaptation, not root integration or runtime closure.
The hotfix ownership-preserving transaction API from `a0d0e896` belongs to the excluded
dependency scope and is not reproduced or claimed by ordinary `asyncWrite`. Preserved-
incarnation same-storage/account replacement, restart recovery, native script-preview
request lifetime and both-platform mounted qualification remain open. Failed retirement
after the editor is released is logged; no durable draft retry journal is introduced.
Upstream root remains `3c10696d33c294e6657945d66353212ce4b76c43` with Lake pin
`808dbaf3721af9903aa4cba827b791c17581e4e3`; observed hotfix root remains
`1da64556cb01276c26be393ce0ae09f79ee0de2a` with pin/checkout `036d4193` and 766 dirty
entries. Those dirty changes are WIP evidence only and were not touched. Original Lake
and LakeKit checkouts retain `e154c93d` and `29db685f`. No root pin changes are included.
The next concrete script-family gap is captured native preview navigation admission after
enqueue/disappearance, composed with pending #50's existing `shouldLoad` mechanism.

### Hotfix port: script allowed-domain commands

At draft `d41118fb`, domain text hydration/editing selects the global Realm configuration
after delay and does not admit script membership, deletion or editability in the final
transaction. Script form deletion computes IDs from then-current offsets; add/context-menu
delete also obtain their owner after enqueueing work. Hotfix
`3d9791093686f75aeb2e091d3c9a06c44d7bb9cf` introduces the captured allowed-domain editor
and rendered-ID commands, retained at exact tail `64f65fbb39238d126700ab3f9d4df59fd76a701c`.
The hotfix cell/helper moved into `LibraryManagerView.swift`; this adaptation preserves
main's separate cell and current library composition. Pending #95 `21c42ff0` still has the
old domain/model paths; #50 `0b91431f` has no captured domain editor. No pending owner is
duplicated by this tranche.

The new `LibraryScriptDomainCommands.swift` captures storage, script ID/createdAt and
domain ID/createdAt at rendering/input. Every text/add/delete mutation resolves its live
owner on RealmBackgroundActor and checks deletion, editability, membership where relevant
and captured incarnation in the final transaction. Rendered deletion selects stable IDs
and dates before queueing, survives reorder and excludes recreated rows with the same ID.
It retains synchronized tombstones, shared batch timestamps, add-before-refresh metadata
and no-op journal suppression. It does not implement the hotfix dependency's unavailable
ownership-preserving transaction API or a global account/storage-generation fence.

The cell initializes State from the captured row without sending hydration into its write
binding. User input reserves a shared transient intent before debounce; pending writes and
reopened editors share ordering for the domain row, including two admitted script owners.
Latest unchanged input retires older work without a journal mutation. Disappearance flushes
the latest captured command; row identity includes storage and both incarnations. UI list
tasks observe errors through the stable `# LIBRARYSCRIPTDOMAIN` prefix. These are authored
source paths, not mounted UI qualification.

Nine regression methods exercise captured storage after replacement, six retirement/
replacement cases during a suspended writer, newer no-op input before commit, rendered
list deletion after reorder/storage replacement with repeated/out-of-range deletion,
shared-domain ordering across script owners, recreated selected-domain exclusion, add
journaling plus managed-owner rejection, pre-cancel rejection and cancellation of suspended
text/add commands. Fixtures are private
in-memory Realms; all fixture mutations use RealmBackgroundActor. Test/source directories
belong to the existing package targets, but compilation, test discovery and execution remain
unverified. Only source/API/history review and whitespace checks ran. Root pins and original
checkouts remain unchanged.

This closes the focused domain mutation gap in candidate source only. The subsequent
October 11 continuation above adapts script field ordering, retirement and observation;
native preview navigation remains open. Same-backing storage/account reset with
preserved createdAt, cross-script domain-deletion ownership policy, restart and both-platform
mounted qualification remain separate gates; this is not closure of the entire script form.

### Hotfix port: physically invalidated reader rows

Hotfix `50dffbec4228a791f519b78c12c070d9843fae84` adds invalidation guards across
ReaderContent reuse, preload, title refresh, resolver publication and access; subsequent
`cf64f5eb326b6ad56e2d4f6528c586253abcd7d6` adds valid cached model/title accessors.
These are present at the separately inventoried hotfix-tail endpoint `6e492b3e` and absent
from upstream draft `65631f91` and pending #50 `0b91431f`. This tranche adapts those
specific contracts to current upstream selection ownership and diagnostic logging.
It retains the display URL and last admitted contentTitle when the cached Realm row is
removed, rejects that row for reuse/publication/access, and permits a fresh resolver retry.
Diagnostic reads also validate old/new/local rows so logging does not bypass admission.
The resolver checks again after synchronous publication callbacks.

Five regression methods cover both matching/moved display reloads, removal before/after
preloading, live cached title versus retained projection and deleted cached access, a
deleted resolver result with a pending accessor and successful retry, and synchronous
Realm invalidation by a title subscriber. All storage fixtures are private in-memory
Realms, mutations use RealmBackgroundActor, and creation/title edits retain explicit
metadata refreshes. Physical removal simulates acknowledged cleanup, not production
deletion policy. The package test target includes the directory and required products.
Sources remain uncompiled/unrun; only source/API/history review and whitespace checks ran.

Fresh Lake hotfix observation `64f65fbb39238d126700ab3f9d4df59fd76a701c` is an ancestor
continuation of `6e492b3e`: three additional commits change only
`ReaderContentSelectionHandoff.swift`; ReaderContent and its storage regression file are
unchanged. That new handoff tail is observed, not semantically closed here. Main remains
`8985bf92`. Selected Reader hotfix root/pins and the original checkouts were not edited.
Full selection handoff/cancellation, mounted callers of the new cached accessors,
soft-tombstone display policy and root/platform qualification remain open. The previously
proposed generic consumer-cancellation checks are deferred under the updated hotfix-port
objective; they are not part of this commit.

The [feed-preview navigation handoff](20261010-reader-dependencies/feed-preview-navigation-handoff.md)
at candidate `7867feb3` identifies the remaining queued-task/native-request lifetime and
rechecks pending #50's existing `shouldLoad` API. That mechanism is already pending source;
the current preview caller needs request/incarnation/disappearance admission when composing
it. No duplicate navigator mechanism, production navigation patch or runtime claim is added.

### Caller-resolved ReaderContent selection

Source review at `a738497d303aadc97c90af43e0396beab88c32fb` confirms the three production
feed-preview assignments in `LibraryFeedView.refresh` bypassed asynchronous selection
retirement. An older resolver could publish during the navigator's loader/prefetch awaits.
The focused repair exposes `ReaderContent.replaceSelection(with:)`, retiring the previous
receipt and resolver before installing caller-resolved content or clearing it. Those three
preview paths now use the explicit method; internal resolver publication and title refresh
remain unchanged. Display URL/navigation stays with its existing owner.

Three runtime regression sources cover a noncooperative old resolver after caller selection,
clearing the selection, and a pending accessor during a synchronous A→B→same-object-A
replacement. The round-trip occurs through production title publication before the original
producer returns, so the accessor must reject its retired receipt even when object identity
matches again; subsequent access accepts the new selection. This improves the earlier
missing same-object oracle for this explicit replacement path, not every legacy setter.

Source/diff review and whitespace checks only; no tests/builds/CI/native launch ran. Other
external direct property setters remain legacy paths, and queued preview tasks, native
navigation ownership/cancellation and mounted feed switching still require reconciliation.
The new API does not claim to fence those separate continuations or account/storage writes.

### Consolidation tie-policy review

At draft `c6ab8816c0846fab2162a0ad34e434d15134e30a`, source review of
`LibraryConfiguration.getConsolidatedOrCreate` confirms survivor selection, relationship
admission, duplicate tombstones and metadata refreshes occur in one final transaction.
Existing unresolved primary relationships survive; resolved retired targets are excluded;
new candidates use immutable created-at and source-configuration/ordinal keys. Repeated
unchanged consolidation does not refresh primary metadata. No new production defect was
found in this bounded slice.

One added runtime regression source tests unresolved candidate ties with opposite duplicate
arrival order, resolved/unresolved equal-date precedence, preserved unresolved primary
placement, duplicate-ID deduplication, retired-target exclusion and unchanged journal
generations on rerun. It invokes actual consolidation and reads Realm state; it does not
assert implementation text. Regression compilation/execution remains unverified.
Source/diff review and whitespace checks only; no build, test, CI or native launch ran.
Late CloudKit delivery-order convergence, script-specific unresolved ties, account/storage
admission and mounted integration remain open. This does not close the entire library ledger.

### Final inventory row admission follow-up

Source review at `56ae27b6d5a443c3f9aa94815ce08b0342f977ae` found that full inventory
retained resolved Realm objects across orphan reconciliation and published them without
checking their final live state. The typed `files(ofTypes:)` accessor filters deletion,
so this is a public inventory consistency defect, not proof that a typed book list displays
deleted rows. The repair retains compound keys and captured URLs across the await, refreshes
the captured Realm after reconciliation, checks the receipt again, and re-resolves only
present, undeleted, matching rows immediately before `files` publication. Import's final
row lookup also explicitly refreshes before admission. Existing orphan tombstones and
their metadata refreshes are unchanged; no deletion is undone.

The import-deletion regression now also requires an empty published inventory. One additional
production-owner regression tombstones a discovered row after reference resolution and
before orphan reconciliation, then checks empty publication, preserved tombstone and
unchanged physical bytes. Both sources are uncompiled/unrun. Source/diff review and
`git diff --check` are the only verification. Same-key deletion/recreation incarnation,
later deletions after publication and account/storage ownership remain separate open gates.

The subsequent [upload/import ownership follow-up](20261010-reader-dependencies/import-upload-owner-handoff.md)
traces physical-copy and completion gaps at candidate `39567c8f`, compares pending #50's
stronger storage/final-record behavior, and records the exact Lake/SwiftCloudDrive boundary.
Its subsequent repair carries the original inventory selection through new-copy import
and re-resolves final records after refresh. Four further regression sources cover early
drive/configuration replacement, post-indexing replacement and final-row deletion. Physical admission inside
SwiftCloudDrive, immutable snapshots and #50 storage-helper composition remain open.
Verification is source/diff review and whitespace checks only; no runtime closure is claimed.

This bounded pass starts from Lake draft #138 `e154c93d4a516650faaaf2c251da838512253018`
and LakeKit draft #13 `29db685f7145182445324ac0d8aefbd58eb6f3c2`. Fresh isolated-copy
fetches confirm main remains Lake `8985bf92b9504d53e00025e4054b3aa97f876e45` and
LakeKit `ce5732052d1480329b4b1c47f1440877dedf0e41`. Original task-18 checkouts remain
preserved at their starting heads. The local parent context is clean at
`3c10696d33c294e6657945d66353212ce4b76c43`, selecting Lake `808dbaf3721af9903aa4cba827b791c17581e4e3`;
it does not select this candidate. Hotfix root is still `1da64556cb01276c26be393ce0ae09f79ee0de2a`,
dirty, selecting Lake `036d4193078016db0becdf91b86dd34fb1d579e0`; no original checkout was edited.

**P1 repaired in source:** `ensureImported(downloadable:)` could scan an existing library
file under receipt A, suspend in `publishDiscoveredFiles` while opening Realm, then merge A's
rows into receipt B's current visible list. The method now captures selection before its
first await and carries it through existing-file scan and partial publication. Admission
after URL lookup, scan, Realm opening and final refresh prevents stale success or visible
merge; the final merge has no intervening suspension after admission. The scan's existing
durable mutation admission and journaling remain unchanged. No rollback of an already
admitted scan write is claimed.

Three new production-owner regression sources in `ReaderFileInventoryOwnershipTests`
cover replacement drive retaining only successor files, configuration-only replacement
rejecting old publication, and successful current-receipt import. The instance partial
publication seam pauses after Realm opening without replacing scan results. Existing
bounded entry/result helpers release and cancel the producer on failure. Source inspection
confirms the pre-repair publication has no receipt argument or check; the new tests were
not executed and no failing/passing runtime result is claimed.

**P2 LakeKit fixture repair:** its cancellation regression waited indefinitely for a sleep
that a broken helper might never enter. Draft #13 replaces that entry wait with a bounded
XCTest expectation and guarantees cancellation/continuation release on exit. Production
progress cancellation and purchase layout are unchanged. Native layout remains unverified.

Scope remains the assigned 13-name partition: LakeOfFire, swiftui-webview, LakeImage,
LakeKit, SwiftUIDownloads, FaviconFinder, SwiftUtilities, SwiftSoup, Cache, swift-tiptap,
markdown-webview, Portal and Popovers. Popovers has no preserved task-18 checkout and no
gitlink at the observed hotfix root; it was not initialized or audited as available source.
Historical swift-readability inventory is not added to this pass's ownership. Only the two
draft repositories' current remote heads were refreshed, not all historical inventory refs.

Remaining: the new-copy/upload branch of `importFile`, opaque processor side effects,
account/same-backing storage generations, persistent suspension and lossless waiter policy;
broader Reader/EPUB and feed durable admission remain open. The prior frozen Core handoff
at `d50a8c2c` still identifies modal-open and debounce edit-origin capture and the fresh-main
completion-proof adapter; it was not refreshed or edited in this pass. Realm ownership APIs
and schema12 producer/transport integration remain with their owners. This pass does not
close whole-file or historical finite inventories.

Actual verification: source/API/caller and diff inspection, fresh draft/main refs, and
`git diff --check`. No builds, tests, benchmarks, package resolution, generators, native
launch/capture or CI dispatch. All new commits use `[skip ci]`. Root pins, settings,
original dirty work and idle/native workers are unchanged.

This is a **bounded progress report, not comprehensive completion**. Source review found and implemented focused missing ports in LakeOfFire and LakeKit. Remaining source families and test comparisons are explicitly unresolved below and in the linked path ledgers. Builds, tests, benchmarks, native apps, package installs, project/test generators and CI dispatch were **not run by request**. No test-pass claim is made. Source work continued into 2026-10-11 UTC; the audit window remains 2025-10-10 through 2026-10-10 inclusive.

## Boundary and evidence tiers

- Fetched hotfix root: `8008cf2d84fb4aa331f4b226775cc38270925311`; local hotfix root: `1da64556cb01276c26be393ce0ae09f79ee0de2a`, dirty. Hotfix committed Lake pin: `036d4193078016db0becdf91b86dd34fb1d579e0`.
- Fetched upstream root main: `b3f8340bdbfd7d3c8de681dd1234bcd42eff650c`; local upstream root: `3c10696d33c294e6657945d66353212ce4b76c43`, dirty. These roots are observations, not release claims. Main root selects Lake `269f26450fa565326c6031e43da51211a7b2b67c`, while the local root selects `808dbaf3721af9903aa4cba827b791c17581e4e3`; neither equals the dependency-main target below.
- Dependency targets were freshly fetched, and pending dependency PR heads fetched into `refs/remotes/audit/pr-N` before editing. All 13 valid owned repository histories are non-shallow. Source commits and dependency main are distinguished from root selection and dirty WIP throughout.
- Work was isolated under `/Users/alex/Documents/Codex/2026-10-10/task-18`. Original dirty user files, existing worker branches, screenshot work, root gitlinks and excluded source repositories were not edited. Six authorized Sol 6.1 Medium subagents reviewed disjoint slices; additional independent source reviews checked the proposed ports and the selection continuation.
- Repository reconciliation/BigSync/SwiftUI instructions were read. The newer user instruction superseded historical model/build defaults. Local Codex memories had no matching available stored rows; the live root `specs/HOTFIX-PORT.md` was read critically as historical/current claims, never as proof. Shared root documentation was left to the parent.

## Finite inventory

The inventory contains **2,626 dated reachable commits, 3,205 unique dated paths per repository, and 1,098 exact endpoint-differing dated paths**. Counts include moved, deleted, test, resource and historical evidence paths. They are coverage operands, not completion percentages.

| Repository | Selected hotfix source pin | Fresh dependency-main target | Dated commits / paths / differing paths |
| --- | --- | --- | --- |
| LakeOfFire | `036d4193078016db0becdf91b86dd34fb1d579e0` | `8985bf92b9504d53e00025e4054b3aa97f876e45` | 1405 / 1182 / 1036 |
| swiftui-webview | `da0ec9394a3a89734768768ad7b8cb6082ac9d80` | `da0ec9394a3a89734768768ad7b8cb6082ac9d80` | 239 / 50 / 0 |
| LakeImage | `3270761611fa85b4b6129227b4adf2bbda4be5a0` | `3270761611fa85b4b6129227b4adf2bbda4be5a0` | 11 / 5 / 0 |
| LakeKit | `a5db41e0ca326cb0cbe0094dcce9fcdff2160a6b` | `ce5732052d1480329b4b1c47f1440877dedf0e41` | 126 / 50 / 16 |
| SwiftUIDownloads | `fc5c35173e440309c89828a673bcaa485248eaf9` | `18077d0cd9506c40dccafeb754f58b6599987337` | 114 / 47 / 1 |
| FaviconFinder | `9fdaeba2c01bd9692d79029b5179205eac7276bc` | `27f81e1b66d3934890f7e7858c803cf0d27a6113` | 9 / 14 / 9 |
| SwiftUtilities | `f437c7d06fc631cd7a67731279411c417cdf8077` | `9df24a7809f5b681c8480ba7ef681335977f0fc5` | 5 / 5 / 2 |
| SwiftSoup | `913459c5b97b6d4a63fec4ca676328be7a593e18` | `c4e4fa991232ba4861f44b2d1a26113b31dfe142` | 348 / 348 / 33 |
| Cache | `0e60e5f2261a6011182c8ce699067970b99aa206` | `bc0cb5bdc2c4a55fe4b156639ed9e16ed86b99c2` | 7 / 9 / 0 |
| swift-tiptap | `55e8bb9d8c08519cbefe0e6de5697a21703b3481` | `2e09ca86cdc66cf6b058763fbdbd868b671c310b` | 41 / 28 / 0 |
| markdown-webview | `1fde64c3fce117800635d58f57b8478ca4f1ceb6` | `f2e42f5f2ddeecc960c6390d1acfc59e1b5ba42a` | 2 / 2 / 1 |
| swift-readability | `438724ab13e428a01ba4bb10ff6fbc8fa6c7330b` | `438724ab13e428a01ba4bb10ff6fbc8fa6c7330b` | 25 / 1167 / 0 |
| Portal | `424c0dc1b7bb327491b573d74f1ca8253df834e8` | `424c0dc1b7bb327491b573d74f1ca8253df834e8` | 294 / 298 / 0 |

Reproduction: enumerate `git rev-list --since-as-filter=2025-10-10T00:00:00Z --until=2026-10-10T23:59:59Z <hotfix-pin>` using committer time. Enumerate that lineage's `git log -m --root --format= --name-only` paths, then intersect with the direct endpoint tree diff. Renames/module moves are translated separately. This does not use cherry-pick equivalence to conclude behavioral parity or treat all old endpoint differences as dated work. Older code was read only for owning-call-path context.

[Commit inventory](20261010-reader-dependencies/dated-commits.tsv) and [dated-path dispositions](20261010-reader-dependencies/dated-paths.tsv) preserve the finite inputs and unresolved rows. The [Reader translated-path ledger](20261010-reader-dependencies/lake-reader-coverage.tsv), [Reader test comparison ledger](20261010-reader-dependencies/lake-reader-test-coverage.tsv) and [editor/parser ledger](20261010-reader-dependencies/editors-parsers-path-ledger.tsv) provide more specific coverage. These requested audit operands are not build/release gates, per-file hash allowlists, source-copy packages or retired validation systems.

Deterministic inventory review was supplemented by recorded shuffles with seed `20261010`. Each slice report records exact order/results; [root cluster order](20261010-reader-dependencies/root-shuffled-pass.txt) and [SwiftSoup order](20261010-reader-dependencies/editors-parsers-shuffle.txt) are retained. Random exploration never replaced accounting.

### Recursive discovery corrections

Committed `.gitmodules` was inspected recursively, including excluded parents for discovery only. The initialized owned set is the 13 repositories above. `Vendor/Popovers` is a stale declaration with no current gitlink. `ManabiMeCab/Sources/mecab` is likewise a stale declaration: selected `37f46ddb913731d2a8aa356053597cf913aa2dd5` is a **tree**, not a commit/gitlink. An initial helper resolved that child directory to the excluded parent Git root; the invalid inventory entry was removed, and the mistakenly created clean task worktree/commit-free branch were removed. No MeCab-parent source was edited. A read-only isolated engine clone confirmed remote master `4eb36c8b19aeac5e87446824bde823a7ca20dd95`; it is not evidence for a selected nested hotfix repository.

Neither selected hotfix root nor initialized dependency histories establish a recursive Brave gitlink. Upstream root main separately declares `swift-brave` (`84f2ba37df3992db73f62b99a3389cee886cbce5`) and `brave-core` (`d8cf473030eaf3bac8a7c1fc87049f146e83daf3`). Their selected trees have no nested gitlinks/.gitmodules. Lake main's Adblock/reader graph imports SwiftBrave products; selected SwiftBrave uses the checksummed binary `BraveAdblockCore` and its own WebMedia sources. These upstream-only reachable owners are retained, not automatically restored into hotfix. WebView's Brave URL extensions are attributed copied source, not a recursive repo. No unrelated Brave monorepo was swept into the hotfix inventory.

## Implemented focused ports

| Behavior | Source result and regression source | Remaining limit |
| --- | --- | --- |
| History cached miss | Rechecks live/canonical aliases inside the write; preserves captured title/body/flags and tombstoned loader aliases; only an actual visit resurrects/updates visit time. `ReaderHistoryMissPreservationTests`. | Broader loader request/configuration/selection publication remains open. |
| ReaderContent selections | Retires displaced work before cached/preloaded publication, uses producer-owned slot cleanup and persistent selection/object admission for awaited results. Eleven `ReaderContentSelectionOwnershipTests` use the actual owner/resolver. | Deterministic same-object ABA completed-delivery oracle, mid-flight cancelled-owner lifetime and direct content-setter callers remain open. |
| Feed body authority | Explicit feed full-content authority carried parser→payload→mirror; missing/summary bodies preserve captured full bodies; unchanged-entry body-only promotion preserves reader enrichment and suppresses equal replay. Bookmark/history creation routes use the same guard. `FeedContentPreservationTests` and production parser/Realm tests in `AsahiFeedReadabilityPipelineTests`. | Full feed account/configuration ordering, enrichment partition, durable mirror debt and mounted/cold-reopen proof remain open. |
| Atom audio | Publishes ordered audio array and singular compatibility value; URL-list comparison catches secondary-only changes. Actual Atom refresh test follows entry→bookmark/history arrays while preserving captured content. | Navigation consumer/platform execution remains unverified. |
| Drive preparation | Prepares optional cloud + required local before tuple publication; rejects canceled/superseded attempts, propagates local failure and retains previous tuple on preparation failure. Four controlled preparation tests. | Success means preparation only. Legacy background inventory/orphan reconciliation is **not** generation-fenced. |
| EPUB metadata | Selects nonempty title/creator, consumes CDATA, honors namespace/direct-depth main-title refinement and rejects internal/external entity declarations while retaining main graph/date checks. Nine `EPubMetadataSelectionTests`. | Whole serving/session/fingerprint tuple and existing large test suites still require reconciliation. |
| Theme | Compares three body datasets and body/root inline color-scheme before DOM writes; repeated application reports zero changed docs. Two JSCore tests execute actual evaluator output with mutation counters. | Core's separate global theme owner, style-drift/mounted and both-platform proof remain open. |
| Google query | Decodes encoded parameter names and values once, preserves literal `%2B`, form spaces and first empty value. Four `GoogleSearchQueryTests`; provenance hotfix `d6e8bc8d69e347405f36aad72ce51bd60db11fe6`. | Native compilation/execution unverified. |
| LakeKit progress | Cancellation checks before/after sleep on MainActor plus disappearance cancellation prevent old hide/reset from affecting successor progress. Four runtime helper tests. | Root test membership and mounted progress ownership unverified. |
| LakeKit store layout | Ports documented ordered layout candidates and narrow availability erasure; keeps stronger main onboarding/load/accessibility behavior. | Current SDK compilation and actual resize/Dynamic-Type layout not verified. |

Lake implementation commits:

- `5823a90235e9d895dd0732a7d6e030cba11e451a` — Retire displaced Reader content selections [skip ci]

- `b66839466a38c7f6e18207910eacb6211ba5905f` — Preserve encoded Google query names and empty first values [skip ci]
- `fad4afc6a85419fac83256f40a486bf1d96fd59d` — Suppress unchanged Reader theme DOM writes [skip ci]
- `20844a251a6cb0b24203b710cfaa16b026181dec` — Port EPUB metadata selection and declaration safety [skip ci]
- `88fb3bd85d54d1ae88bb965db94273d65a1a055a` — Fence Reader drive preparation before tuple publication [skip ci]
- `48e3935b3859e97adf4fa0e6cab9967a91d09c5a` — Preserve captured history and feed body/audio authority [skip ci]

LakeKit implementation commit: `29db685f7145182445324ac0d8aefbd58eb6f3c2`. The earlier unpublished `e02a984` message was amended for CI skipping without changing its tree.

New Swift tests belong to existing owning SwiftPM targets by source-directory membership. This establishes source ownership, not discovery/execution. Root explicit LakeKit test-source membership does not yet select the new progress suite; root edits are parent-owned. Existing meaningful upstream regressions were preserved, including stronger Downloads native-delegate lifetime coverage, SwiftSoup output/Unicode/parser fixes, LakeKit session/share ownership and Favicon request-origin policy. No retired validation, dependency pin, obsolete navigation/backend or media stack was restored.

## Existing PR comparison and ownership

No existing PR was reused or modified: no fresh evidence established that a relevant active branch was unowned. The exact frozen heads below were inspected by relevant subsystem, including pending upstream coverage and hotfix-only bases. Main-target branches and branches stacked on main-target #50 are pending upstream evidence, never main completion. #50's `0b91431f` movement of `importIdentity` into `DownloadableBookGridCell` was preserved; this task never edited that cell.

| PR | Frozen head | Base | Evidence tier |
| --- | --- | --- | --- |
| [LakeOfFire #137](https://github.com/lake-of-fire/LakeOfFire/pull/137) | `8b9d8381ce7561625452545b99260b29aaf81f37` | `v3-hotfix` | Hotfix branch only; no upstream closure |
| [LakeOfFire #113](https://github.com/lake-of-fire/LakeOfFire/pull/113) | `9ef23abaecf93eb24dfbe55cbf02e9598f4f935f` | `v3-hotfix` | Hotfix branch only; no upstream closure |
| [LakeOfFire #95](https://github.com/lake-of-fire/LakeOfFire/pull/95) | `21c42ff0138c0b5b934956cbcccd107e5c577cf6` | `main` | Pending source; no selected-main or runtime closure |
| [LakeOfFire #74](https://github.com/lake-of-fire/LakeOfFire/pull/74) | `ad19065bd567f09f64a7f321feb2087fd60701fa` | `port/epub-serving-safety-integration-20260928` | Pending source; no selected-main or runtime closure |
| [LakeOfFire #61](https://github.com/lake-of-fire/LakeOfFire/pull/61) | `0dc1e429fc8e2d2b7e7f2a176fe2f72fabc7ab9e` | `port/epub-serving-safety-integration-20260928` | Pending source; no selected-main or runtime closure |
| [LakeOfFire #59](https://github.com/lake-of-fire/LakeOfFire/pull/59) | `0dd0b07afac69c6d02512a7b02ff2acb27bf7bb0` | `port/epub-serving-safety-integration-20260928` | Pending source; no selected-main or runtime closure |
| [LakeOfFire #54](https://github.com/lake-of-fire/LakeOfFire/pull/54) | `28c6911ada2221bc9a390de65f31b79bfba84bd4` | `main` | Pending source; no selected-main or runtime closure |
| [LakeOfFire #53](https://github.com/lake-of-fire/LakeOfFire/pull/53) | `35e0a7e65ce63365a9923a92fac832ad087c549b` | `main` | Pending source; no selected-main or runtime closure |
| [LakeOfFire #51](https://github.com/lake-of-fire/LakeOfFire/pull/51) | `547b1e88a836c8c4b53c24c98294700e9066a745` | `main` | Pending source; no selected-main or runtime closure |
| [LakeOfFire #50](https://github.com/lake-of-fire/LakeOfFire/pull/50) | `0b91431f0fe04c45b24b08b427a5df66e87661b9` | `main` | Pending source; no selected-main or runtime closure |
| [LakeOfFire #48](https://github.com/lake-of-fire/LakeOfFire/pull/48) | `2f3a63733583e179bddc8025a7320141fc1ddade` | `main` | Pending source; no selected-main or runtime closure |
| [LakeOfFire #41](https://github.com/lake-of-fire/LakeOfFire/pull/41) | `af14b895d9d3e1a1fe8c3a00e52c158d6eae211e` | `main` | Pending source; no selected-main or runtime closure |
| [swiftui-webview #23](https://github.com/lake-of-fire/swiftui-webview/pull/23) | `c13e5da5b343f56631234d6d9957655dd91d5d04` | `main` | Pending source; no selected-main or runtime closure |
| [swift-tiptap #4](https://github.com/lake-of-fire/swift-tiptap/pull/4) | `5d8c78560db7b20ea602f7d50a1a35a2173d25d9` | `main` | Pending source; no selected-main or runtime closure |

TipTap [#4](https://github.com/lake-of-fire/swift-tiptap/pull/4) removes existing iOS hosted readiness/ruby tests and accessibility IDs; it is not a superset of hotfix behavior. WebView [#23](https://github.com/lake-of-fire/swiftui-webview/pull/23) contains newer receipt/configuration/transition work; do not duplicate it. Downloads main replaces the hotfix's obsolete nil-native-delegate expectation with a stronger retained-proxy/late-callback regression. Cache/Portal checkout presence did not establish current production linking. Byte-identical package endpoints do not prove app-pinned/browser/native integration.

## Critical corrections and remaining work (prior tranche; continuation below supersedes scoped findings)

1. **P1 inventory lifetime/durable effects:** old drive scan A may publish `files` and orphan tombstones after tuple B installs; B's non-force shared-task join/debounce can lose its successor scan. Merely using `force` does not fence A's effects. Implement captured storage/configuration generation and check it at per-file persistence, final publication and orphan transaction, with successor queue/waiter policy. The first draft's awaited-refresh success claim was removed; current preparation-only port keeps this explicit.
2. **P1 Reader document mutation admission:** metadata/image/RSS work still needs captured document/lifecycle admission through async content resolution and durable writes. URL equality and same-named fields do not close replacement/ABA. See exact Reader rows; don't copy the moved monolithic viewer over decomposed main.
3. **P1 ReaderContent ownership, narrowed by continuation:** candidate `5823a90235e9d895dd0732a7d6e030cba11e451a` ports load(url:)-based cached/preloaded retirement, producer cleanup and completed selection/object admission. This does not cover public direct setter retirement (LibraryFeedView preview), mid-flight cancelled-owner lifetime/handoff or the separately observed tail contract. Durable title commands still lack captured-target/commit-before-publish behavior. Exact parent-owned callers are Core SnippetAppendBar.presentRename and LookupsSnippetReaderView’s debounced editable title; see continuation for frozen Core objects/paths.
4. **P1 library form/consolidation:** #95 carries captured Realm commands but does not close live `LibraryFeedView` field ordering, record incarnation/metadata-fill admission or immutable consolidation relationships. Script/editor/category/observer paths need the precise remaining slice review.
5. **EPUB pending/partial:** #50/#74 contain substantial producer/session/renderability behavior, but deflated empty-directory validation, schema12/sidecar retention and complete producer/bridge/decoder/restore tuple are not closed. Root/API integration remains parent-owned.
6. **Settings API boundary:** fresh excluded Realm main `ffb9b50248291b7f13d6df42a27d8f1383ca618e` does not expose hotfix `asyncWritePreservingOwnership`. Reader Settings clear-history/unsaved-feed call sites cannot be copied against an invented API. Report to the parent dependency owner.
7. **FeedView projection deliberately deferred:** canonical duplicate removal needs ordinary selected occurrence and collection membership policy. An attempted projection preserved raw collections but could orphan ordinary selection; it was removed. FeedView is unchanged. The gap remains genuinely missing/needs adaptation, not a finished port.
8. **Readability/style integration:** Lake's browser copied Readability JS differs from current package resources. Native/package equality does not prove browser parity; ebook Reader CSS isolation also remains unresolved. Preserve package/source ownership rather than restoring old copied monoliths.
9. **Shared WebView limitation:** explicit `.allow` can return before pooled domain-script refresh. Identical hotfix/main and #23 leave this existing integration oracle open; no affected production domain-restricted caller failure was proved, so no speculative fix.
10. **Remaining finite review:** Reader ledger has 128 unresolved source rows and 76 unresolved dated test comparisons; files/books has 47 source/45 test rows with the explicitly qualified large handler/test-body boundaries; content/library lists 25 existing test files still needing complete semantic reconciliation. Exact unresolved paths are linked below. Mechanical equality accounts for unchanged/relocated assets and fixture/reference corpora, not independent review of every body. No comprehensive source/test/caller coverage is claimed.

Independent review caught alias-tombstone and authority-only promotion omissions; both were corrected and re-reviewed. The duplicate projection was deferred. The initialization promise was narrowed after review caught stale shared-inventory acknowledgement. Historical findings remain in the [content independent review](20261010-reader-dependencies/lake-content-independent-review.md) and [UI/files independent review](20261010-reader-dependencies/lake-ui-files-independent-review.md), with final resolution/remaining limits.

## Slice evidence and exact next boundaries

- [Files/books](20261010-reader-dependencies/lake-files-books-report.md): source/test rows, pending handler/fingerprint/session concerns and shuffled order.
- [Reader](20261010-reader-dependencies/lake-reader-report.md): translated resources/owners, exact unresolved source/test list. 255 exact PDF blob moves account for 510 dated path rows.
- [Content/library](20261010-reader-dependencies/lake-content-library-report.md): full-body/audio/history ports, remaining selection/editor/feed/style boundaries and test file list.
- [WebView/downloads](20261010-reader-dependencies/webview-downloads-report.md): all 97 dated paths, actual callback/receipt/retained-delegate consumers and outstanding integration.
- [Editors/parsers](20261010-reader-dependencies/editors-parsers-report.md): 1,554 dated paths, stronger main behavior, TipTap #4 and Readability consumer boundary.
- [Small dependencies](20261010-reader-dependencies/small-dependencies-report.md): 372 dated paths, LakeKit candidate, retained stronger behavior and stale nested discovery correction.

## Publication and verification

Publication is limited to new draft PRs for reviewed source candidates and this task-specific evidence report. Root integration, shared ledger updates, merges, PR closure, deployment and production changes remain untouched. Immediately before publication, fresh origin main heads and all existing open PR heads for all 13 owned repositories were rechecked and matched the frozen inventory. Hotfix/upstream root remote heads also matched the frozen observations. The audit window was not extended. CI skipping uses `[skip ci]` on every Lake candidate commit and LakeKit HEAD, supported for push/pull_request by [GitHub documentation](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/skip-workflow-runs). No workflow dispatch was made. Lake candidate/main contain no `.github/workflows` files; LakeKit's three workflows trigger pull_request/manual dispatch, have no pull_request_target, and GitHub reported them disabled_manually. Retired hotfix workflows were not ported.

Only Git source inspection, targeted history/PR/API reads and `git diff --check` ran. Tests/builds **not run by request**. Source API review cannot claim compilation, platform discovery, mounted behavior, benchmarks, native execution or successful release qualification.

Published new drafts: [LakeOfFire #138](https://github.com/lake-of-fire/LakeOfFire/pull/138) and [LakeKit #13](https://github.com/lake-of-fire/LakeKit/pull/13). GitHub confirmed both draft state and empty check rollups immediately after creation. No workflow was dispatched or enabled.

Final origin main observations remain Lake `8985bf92b9504d53e00025e4054b3aa97f876e45`, LakeKit `ce5732052d1480329b4b1c47f1440877dedf0e41`, and Reader `b3f8340bdbfd7d3c8de681dd1234bcd42eff650c`; root remote hotfix remains `8008cf2d84fb4aa331f4b226775cc38270925311`. Original local root HEADs are unchanged. Both committed local and remote hotfix Reader roots still select Lake `036d4193`.

The independent Lake remote `v3-hotfix` was first observed at `00dcfa75f3f65337450089b2df15ed2be779bb79` and advanced externally during final observation to `6e492b3e2a65b4d8a7e49a0e196152d82b6bdc04`, beyond that selected pin. Its 39 within-window additional reachable commits and 89 unique dated paths are separately recorded in [tail commits](20261010-reader-dependencies/remote-hotfix-tail-commits.tsv) and [tail paths](20261010-reader-dependencies/remote-hotfix-tail-paths.tsv). This does not silently expand or close the original selected-pin inventory. It includes newer selection handoff, cancelled same-URL owner retry, file inventory/migration and library/deletion changes; remaining tail source/test rows require review. Its retired validation/tool additions are not candidates for restoration. No tail branch or original user source was edited.

Continuing source evidence: [Core helpers](20261010-reader-dependencies/core-helper-continuation.md) traces AsyncView's actual fixed-pin model and FeedView consumer plus ebook URL recognition/test boundaries. [ReaderContent](20261010-reader-dependencies/lake-content-readercontent-continuation.md) traces fast-path retirement, producer cleanup, completed accessors and the exact parent-owned durable-title callers. The [document-admission continuation](20261010-reader-dependencies/lake-reader-document-admission-continuation.md) traces exact WebView receipt/fence primitives, final Realm mutation admission, separate render-task ownership and existing runtime test source. These refine the unresolved inventory instead of claiming broader closure.

Selection continuation final source commit: `5823a90235e9d895dd0732a7d6e030cba11e451a`. Independent source review found no new bounded source defect; the vacuous scheduler-filtered ABA test was removed rather than treated as coverage. [Selection independent review](20261010-reader-dependencies/lake-readercontent-independent-review.md) preserves that finding and final limitations. Eleven real-owner regression methods remain; deterministic same-object ABA delivery coverage and runtime proof remain open.

Final hotfix-tail observation: external merge `6e492b3e2a65b4d8a7e49a0e196152d82b6bdc04` merged #137. Its committer date `2026-10-10T20:18:03-04:00` is `2026-10-11T00:18:03Z`, outside the UTC window, so the merge is excluded from the dated commit ledger. Its parent source `8b9d8381ce7561625452545b99260b29aaf81f37` is within the window and was already inspected as frozen hotfix-only #137. The newly reachable source commit is included in the separate tail inventory. This external merge does not close an upstream port; no PR was merged or closed by this task. Frozen PR-state evidence above describes the earlier open-PR observation. The continuation reviews retain their captured `00dcfa75` tail object as historical evidence.


## Focused continuation delivered 2026-10-11

This continuation adds source-only repairs for the requested document, inventory, captured-title and library slices to the existing owned draft [Lake #138](https://github.com/lake-of-fire/LakeOfFire/pull/138). Main remains `8985bf92b9504d53e00025e4054b3aa97f876e45`; selected source remains `036d4193078016db0becdf91b86dd34fb1d579e0`. The separately inventoried hotfix tail remains `6e492b3e2a65b4d8a7e49a0e196152d82b6bdc04`; the out-of-window merge was not added to dated source coverage. Earlier reports and review findings are preserved as historical snapshots. The [behavior overlay](20261010-reader-dependencies/continuation-behavior-overlay.tsv) narrows specific functions without pretending their whole changed-file rows are fully reconciled.

| Slice | Authored source and status | Evidence / remaining boundary |
| --- | --- | --- |
| Navigation | `4041cfff`, `1247ea4b`: captured document token for font/committed/finished JS, successor completion rejection, checks after loader HTML/publication lookup. Partial. | [Implementation](20261010-reader-dependencies/lake-navigation-binding-continuation.md), [independent review](20261010-reader-dependencies/lake-navigation-binding-independent-review.md). Four regression methods; callback-entry provenance, render lifetime and later-await runtime oracles remain. |
| Drive inventory | `87fd407a`: captured configuration/drive receipt, scoped producer cleanup, per-file/orphan mutation admission, publish after cleanup, debounce from successful receipt completion. Partial. | [Implementation](20261010-reader-dependencies/lake-drive-inventory-continuation.md), [independent review](20261010-reader-dependencies/lake-drive-inventory-independent-review.md). Failed replacement/forced retries and bounded gates repaired after review. Six regression methods. Opaque async processors, imported partial publication, lossless queue/lifecycle and stronger storage lifetime remain. |
| Snippet rename | `89fe4769`: explicit `updateContentTitle(_:for:)` and persisted-HTML title writer commit before selected UI refresh. Partial. | [Implementation](20261010-reader-dependencies/lake-snippet-rename-continuation.md), [independent review](20261010-reader-dependencies/lake-snippet-rename-independent-review.md). Seven regression methods. Core origin capture and storage/account/final-transaction admission remain. |
| Document durable effects | `89fe4769`: exact native receipt/provenance, revocable framework fence and final Lake metadata/image/RSS writes; dedicated admitted RSS lookup prevents stale fallback creation without borrowing another receipt's URL-coalesced producer. Partial. | [Implementation](20261010-reader-dependencies/lake-document-fences-implementation-report.md), [independent review](20261010-reader-dependencies/lake-document-fences-independent-review.md). Twelve regression methods; native readiness lag and RSS creation defects repaired. Queued native title origin, multi-store rollback/storage generation and mounted integration remain. |
| Library editing / consolidation | `1d3eaef9`: captured Realm/record incarnation commands, shared synchronous field intent, metadata request/final-write admission, user-only retirement flush and immutable relationship ordering. `9e06bc84` aligns direct library test dependency. Partial. | [Implementation](20261010-reader-dependencies/lake-library-editing-continuation.md), [independent review](20261010-reader-dependencies/lake-library-independent-review.md). Nine editing and one consolidation methods. Late cross-editor metadata and canceled replay repaired. Feed.fetch owner/final storage admission remain. |
| Sidecar / restore integration | Existing pending #50/#74 preserved. `51b865e8` fixes current-schema test fixture and adds paired legacy-v9 rejection. Pending / cross-repo gated. | [Report](20261010-reader-dependencies/lake-sidecar-integration-continuation.md), [18 path rows](20261010-reader-dependencies/lake-sidecar-integration-continuation.tsv). Whole EPUB handler/viewer/resource/test clusters remain qualified/unreviewed; schema12 needs matching dictionary/Core migration. |

Two prior claims are refined against exact source. The earlier library statement that #95 carries captured form commands does not describe these field-order/metadata repairs: its endpoint lacks them and its preview differs because it predates newer main recovery. The candidate preserves main's graceful handling. Only the necessary `LakeOfFireLibrary` test-target dependency is aligned with #95; its OPML dependency and stale preview endpoint were not copied. The prior RSS fallback-creation limitation describes the earlier revision and is closed at Lake's owned mutation admission boundary by the dedicated lookup, without claiming transaction rollback after a previously admitted commit.

Fresh excluded Core main `d50a8c2cc66f341bb0a15cbbec3958cef0c1a3d6` still has a two-argument processing adapter in `ReaderModeViewModel+ManabiConfiguration.swift:146`, rename modal `SnippetAppendBar.swift:238` completion calling legacy title API at245, and debounce `LookupsSnippetReaderView.swift:512` legacy call at515. Parent must capture snippet URL at modal opening/edit initiation and carry intent through debounce, then use the explicit title API and handle errors. Capturing current URL only when completion fires is insufficient. The earlier hotfix/root-selected Core `c4b86d15a42e8db174c95fac20b1561f50797a13` **does** have the implicit three-argument completion-proof adapter (`:200–223`) and admission (`:174–179`); a declaration grep missed it. The producer API gate applies to fresh Core main, not that historical pin. No Core/root file was edited.

Fresh excluded RealmSwiftGaps `ffb9b50248291b7f13d6df42a27d8f1383ca618e` still lacks hotfix ownership-preserving transaction contracts. Plain admission checks here are not a captured account/storage API, atomic multi-Realm write, or guaranteed rollback after revocation. Preserve #50 `0b91431f0fe04c45b24b08b427a5df66e87661b9`, including the DownloadableBookGridCell importIdentity fix and richer Yomitan variant tuple. Schema12 hotfix resources under `Resources/Resources/foliate-js` are active translated sources, not blanket retired assets; the original exact resource rows remain unresolved where broader semantics were not reviewed.

Remaining inventory is finite and explicitly incomplete. The original 128 unresolved Reader source rows /76 dated test comparisons and content/library 25-test boundary are retained as baseline coverage accounting; this overlay audits specified functions and newly authored regression methods, and does not silently recompute or close every containing file. The sidecar continuation records 18 dated paths with whole-file versus bounded-function flags. Original files/books 47-source/45-test ledger and additional 89 tail paths remain qualified by their linked slice reports. Remaining queues include full EPUB resource/session/native-owner suites, other Reader render/settings/snippet lifetime paths, imported file partial publication/deletion/migration, feed refresh persistence and category/script/import transactions. Deterministic review and recorded seeded supplements are in each continuation report. No comprehensive completion is declared.

Before updating the draft, all13 owned main heads/open PRs were freshly rechecked and unchanged from this continuation's captured observations; #137 had externally merged as already recorded. Original Reader working HEADs stayed `3c10696d33c294e6657945d66353212ce4b76c43` /`1da64556cb01276c26be393ce0ae09f79ee0de2a`. Their dirty files and active branches were untouched. LakeKit #13 is unchanged at `29db685f7145182445324ac0d8aefbd58eb6f3c2`.

[Publication observations](20261010-reader-dependencies/publication-observations.json) distinguish the historical Actions registry (49 entries including active retired/hotfix workflows) from actual default `main` and candidate trees, which contain no `.github` files. Every candidate commit uses `[skip ci]`; no retired workflow was restored, enabled or dispatched. Only source/API/history review and whitespace checks ran. Builds, tests, benchmarks, native apps, generators and package resolution **not run by request**. Regression source is uncompiled/unexecuted and native discovery remains unverified.
