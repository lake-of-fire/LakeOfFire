# Category list displayed-selection port — 2026-10-11

## Exact source checkpoint

- Upstream parent: Lake #152, `81d69b2dcd6cf21a96ed12de27d9c9ee286e78e1`.
- Hotfix reference: Lake #150 head `38857b1f954e403eff73561caf2769de06bdb9ea`, combined `LibraryCategoriesView.swift`.
- Main uses separate view/model files and ContentPaneRoute. Preserve that architecture.
- Source comparison confirms the hotfix already captures displayed category IDs for offset commands and uses ownership-preserving reorder writes. Main parent still translates offsets through the model's current array and uses ordinary asyncWrite for reordering.
- Existing main DataManager final archive/delete write re-resolves the category and rejects deleted/noneditable targets. This port retains it.

## Changes

- Pass the exact rendered user-category ID order to deletion and movement; refreshed/reordered model arrays must not reinterpret a prior gesture's offsets.
- Retain raw library ordering, configuration creation-time admission, final visible-order equality and hidden-slot preservation; use asyncWritePreservingOwnership.
- Filter invalidated category rows before identity/property access and guard menu eligibility accessors. Remove disabled editor-picks movement/deletion callbacks that incorrectly target user categories.
- Capture the created category ID across delayed navigation and reject a retired/deleted object after the delay.
- Add five real Realm regression methods: deletion after model reorder; noneditable target rejection; displayed reorder with hidden slots; stale stored-order rejection; invalidated menu eligibility.

## Verification and limits

All five new tests are source only: uncompiled and unrun. No native build, project generation, CI dispatch, app launch, deployment, production changes, merges, or root dependency pin advances.
Package test discovery is directory-based. Reader app-level test-plan inclusion remains a separate integration step; no native test discovery is claimed.
This is bounded list-selection parity, not whole-library qualification. UUID-only category commands still do not prove physical-store/account or same-ID replacement admission. Archive-versus-delete intent is still based on current category state. Buffered editor draft/hydration ownership, feed receipt URL provenance, downstream mirror final admission and assembled-root validation remain open.
