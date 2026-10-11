# Archived category route resolution — 2026-10-11

## Exact heads and evidence

Parent: Lake #153 `0c3c79b57773177aaa434dac33df405ccec3ddf1`.
Hotfix comparison: Lake #150 `38857b1f954e403eff73561caf2769de06bdb9ea`.

Main ContentRouteSwitcher resolves category destinations through LibraryConfiguration.getCategories(), which only expands categoryIDs. The archive command intentionally removes the archived category ID. Archive rows also include unlinked, nondeleted categories. Therefore these visible archive destinations cannot resolve through the existing route lookup and fall into Loading Library.
The hotfix route has the same membership-based lookup. This repair is upstream-only here, not a claim that hotfix already contains the fix.

## Changes and tests

Resolve a nondeleted category directly in the live library object's Realm, allowing archived and unlinked archive rows without consulting global Realm configuration. Reject deleted/invalidated libraries and deleted/missing categories. Preserve main ContentPaneRoute and navigation architecture.

Five Realm behavior tests cover archive relationship removal, unlinked archive rows, missing/deleted categories, retired libraries and identical IDs in different in-memory stores.
These are source-level regression additions only: uncompiled and unrun. No native build, generation, launch, CI dispatch, deployment, merge or dependency pin advance.

## Remaining limits and next action

No mounted SwiftUI lifecycle or navigation test has run. This fixes route lookup only. The category StateObject still lacks a route/storage owner boundary; simply adding .id would cancel the current raw-value debounce and could discard a pending draft.
Hotfix provides an owner boundary together with buffered draft retention. Main's script editor has stronger incarnation/intent admission than hotfix's shared editor sequence helper. Adapt those pieces together rather than copying the hotfix manager layout or independently remounting category editors.
Next bounded action: port category draft retention, hydration suppression and final write admission using main's owner/intent conventions, then add the matching editor identity and qualify the assembled target once the test hold is lifted.
