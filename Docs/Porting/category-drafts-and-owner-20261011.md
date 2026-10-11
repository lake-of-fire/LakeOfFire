# Category drafts and editor owner port — 2026-10-11

## Exact comparison

Parent: Lake #154 `4fa0d513a2a03b398a1434e3433f1113baec972e`.
Hotfix reference: Lake #150 `38857b1f954e403eff73561caf2769de06bdb9ea`, LibraryCategoryView / LibraryManagerView and LibraryCategoryPresentationTests.

Main still debounces raw strings, hydrates through the same published properties and refreshes immediately on focus loss. This can discard a final buffered input or turn hydration back into an edit. Main's route also retains the same category StateObject across selection changes. Hotfix addresses these with pending commands, hydration suppression and owner identity.

Do not copy hotfix's older navigation layout or replace main's stronger script editor input-admission design. This adaptation follows main LibraryScriptFieldCommands / LibraryScriptFormSections: immutable record incarnation and Realm configuration, per-field current-input intent, retained pending drafts, explicit completion and retirement flushing.

## Implemented

- Capture category field intent synchronously before debouncing. Hydration does not issue intents; repeated user values after hydration remain valid edits.
- Resolve category ID/createdAt and editability/nondeletion in the final ownership-preserving transaction. Hold the existing-style transient ordering lock across admission and mutation; no persisted field clocks/schema changes.
- Finish flushes both pending fields and exposes a completion task; refresh preserves pending drafts. Failed writes retain their pending command for retry; successful rejected/no-op commands settle without a mutation.
- Retired editors flush captured pending commands to their original owner. Reopened editors share ordering for that category/storage/incarnation, so an older suspended command cannot overwrite newer input.
- Couple this retention with the main route's editor identity (category/storage/incarnation plus library ID/createdAt). Keep ContentPaneRoute, selected-feed binding, main layout and prior #152 feed-deletion guards intact.
- Optional observesRealm=false supports isolated behavioral fixtures; production continues its existing observer.
- Nine behavioral test methods cover immediate Done, no-op/hydration journal stability, out-of-order completion, identical IDs across stores, reopened-editor ordering, changed editability, retirement flush, returning user values after hydration and same-ID replacement.

## Verification and limits

Nine added tests are UNCOMPILED and UNRUN. No native build, test run, project generation, mounted SwiftUI test, app launch, CI dispatch, merge, deploy or root dependency pin advance.
Source review includes the complete main field-command/owner helpers, category model and route, plus hotfix category draft handling. New main methods intentionally mirror established main script-editor patterns rather than importing the hotfix UI wholesale.

Physical file replacement at an unchanged path, account epochs, exact configuration equivalence and same-ID/same-createdAt recreation remain unproved. Category archive/feed commands have their own broader owner-admission gaps; this PR only scopes field writes and view ownership. Durable feed-receipt URL provenance and mirror final admission remain separate.
Next: compile/run this nine-method suite with the #152/#153/#154 category suites and real navigation once the native hold is lifted; preserve unrun status until exact-head evidence exists.

## Source follow-through, 2026-10-11 18:46 UTC

Two additional behavioral methods exercise the actual model entry: cancellation before transaction admission must retain the draft and allow an explicit finish retry; cancellation injected by existing RealmWriteCommitObservation after commit submission must settle durable success without a second journal generation. The latter requires composed RealmSwiftGaps #7 `d718c99064ae16d1d0fdd675224494d6ee8c8ff9` and inherits its task-local seam into the field writer. Eleven methods now exist, all UNCOMPILED/UNRUN. The earlier nine-method count above is the initial candidate's historical checkpoint. No production code or pins change in this test-only follow-through.
