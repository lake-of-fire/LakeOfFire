# Porting work: cross-row book open ownership

Source: Reader-selected Lake hotfix `10fdf15c8ce4550b4e7900830843c1c8f2ac9f98`, primarily BookLibraryView.swift and Book Views.swift plus `BookOpenSelectionOwnershipTests.swift`.
Destination integration: Lake #50, based on main `ac5894d936a15b9d305dafdaeac7afac5a0366dd`.
Root tracker: https://github.com/aehlke/manabi-reader/pull/189

## Ported contract

The selected hotfix owns explicit Editor's Picks opens globally instead of allowing every row to launch independent navigation. A newer selection increments a generation and cancels the previous task. Every asynchronous stage revalidates the exact generation before continuing; a cancelled entrant cannot revoke a healthy owner. The navigation stage receives a live claim and publication is revalidated again after navigation returns.

The main adaptation factors this logic into `BookOpenSelectionCoordinator` so it can be executed without replacing current catalog/import code. `BookLibraryViewModel` keeps the hotfix API shape through typealiases/wrappers. Current `BookCatalogRefresh`, collision-safe storage, import-result state and row-local passive refresh ownership remain intact.

Explicit list-row download/import now runs under the shared selection owner. The row's existing `BookDownloadOperation` remains responsible only for passive refresh/import publication. This avoids having two unrelated owners for the same explicit action. Editor's Picks disappearance cancels the shared owner as in the source.

`WebViewNavigator.load` gains a source-compatible `shouldLoad` argument with a default that preserves existing callers. It validates admission before the initial load, after content resolution, after the optional previous-content fetch, before reader-mode side effects and immediately before issuing the URLRequest. This adapts the hotfix's navigation claim to main's navigator implementation; it does not make earlier loader side effects transactional.

## Tests and boundaries

The normal Lake test target retains the source hotfix's complete `BookOpenSelectionOwnershipTests.swift` for full-host qualification. A focused seven-case coordinator suite executes the same ownership interleavings in a dependency-free SwiftPM graph: cancellation-ignoring older work, cancelled entrant, normal publication, explicit cancel, downloaded-path cancellation, normal downloaded publication, and supersession while the navigator is suspended.

`Tools/test-book-open-selection.sh` runs Debug and Release in explicit Swift 6 mode with warnings as errors. CI runs it on macOS and Ubuntu and frontend-parses the complete real BookLibrary, Book Views and navigator adapter files. Parsing is not a full LakeOfFireReader/SwiftUI/Realm/WebView typecheck.

Keep draft until the full package/root composition compiles the actual adapters and the retained model-level hotfix tests execute. Interactive WebView navigation, row disappearance/reuse, parent publication rebinding and cross-feature selection remain host-level checks. The next separate integration-hardening item is row-state rebinding; the selected hotfix also lacks that fix and it must not be mislabeled as source parity.

No root pins, schemas, historical keys, original books, signing, shared downloader policy, rollout flags or CloudKit settings change.
