# Category editor presentation and displayed selection — 2026-10-11

## Scope and provenance

Parent: Lake #151 `4423c257f9163c5e0f27030b68f196b382c17fe6`.
Compared hotfix Lake #150 `38857b1f954e403eff73561caf2769de06bdb9ea` with the current upstream category editor. The hotfix has captured editor identity and invalidation-safe presentation that the upstream editor lacked. Existing #145 category-list command guards are retained without duplication.

## Focused adaptation

- Capture categoryID at editor construction and use it for SwiftUI task identity and deferred field callbacks.
- Guard invalidated category/menu/image/OPML/feed-list reads and refresh. Retired category commands and direct context deletion of a retired Feed return before reading its primary key.
- Render category feeds from a guarded visible snapshot and pass that exact displayed ID array to deletion. A later rename/order change must not reinterpret the selected offset.
- At the final ownership-preserving feed-deletion transaction, re-resolve and validate the category, feed ownership and editability. A feed moved to a different category is not deleted through the retained old editor.
- Guard duplication candidates/actions and display each destination category's own title.
- Preserve the existing main editor layout, navigation, module split, observing model and source configuration. No wholesale hotfix view/model replacement.

## Verification

Five new behavioral methods use real Realm fixtures: retired presentation/identity, retired category commands, retained displayed selection after rename, moved-feed rejection and retired context-target admission. Existing LakeOfFireTests directory target discovers the file. All methods are UNCOMPILED / UNRUN; root Xcode registration and actual UI/native qualification remain open. No build/test/generation/launch/CI dispatch was performed.

## Remaining boundaries

This does not complete the larger hotfix category-editor family. Main's buffered-draft/hydration and owner-replacement behavior still differs; copying the entire hotfix LibraryCategoryPresentationTests would require APIs absent here. Top-level category list rendering and its displayed reorder/delete mapping remain separate review work. Same-ID reincarnation and physical-store/account admission need the broader ownership design; a captured UUID alone is not that proof.

No dependency pin, schema, retired CI system, production state, merge or deployment changed. Historical test results from the hotfix do not qualify this upstream candidate.
