# Porting work: owned catalog refresh and cancellable consumers

Continues main PR #48 after implementation 33ce2ff4cbdf621071412974c073d5e98b4f6e3a. Destination main remains ac5894d936a15b9d305dafdaeac7afac5a0366dd. The preceding OPDS parser source is pending hotfix #45 at b150e9c71e13f2ae64a729443918a82133fbae74; it is not already selected by Reader.

## Hotfix source and adaptation

Lake v3-hotfix 780c3cfaf8a3422dbaab3e0a87ed84369b126248 contains BookLibraryView.swift blob 67fe945b69ba5f820b96c130eba9403491b5105f. Its Editor's Picks producer checks generation and cancellation before entry and final publication, waits for its task in fetchAllData, and cancels only the waiting caller's owned task. Main's corresponding file was 3f614f47cbe6fb9ef4302209a4c69d8cec5c1ebc and launched unfenced fire-and-forget refreshes.

Adapt that contract into one small MainActor BookCatalogRefresh owner, shared by Editor's Picks and catalog details. UUID request identity replaces an incrementing counter. A cancelled entrant cannot revoke a healthy producer; older results/errors/cleanup cannot replace newer work; cancellation of an old waiter does not cancel the replacement. Weak ownership and deinit cleanup prevent an unstructured retry from retaining its owner. This is request/presentation ownership, not a Realm/sync authority gate.

The actual BookLibraryViewModel now delegates refresh ownership and loading; its public initializer, file/open/download behavior and error presentation are retained. The actual catalog detail view uses task(id:), awaited refresh, owned retry, disappearance cancellation and visible errors. It is moved into a complete independent SwiftUI file, not duplicated. The existing Publication declaration moves unchanged into a Foundation file within the same LakeOfFireReader target; its fields, defaults, Sendable/Hashable identity and access remain.

## Main-native follow-through

Add an async throwing OPDSParser.parseURL overload using URLSession's async transfer and sending result ownership. Existing callback labels and executor behavior remain. Both generic entry points use the same HTTP admission and XML-first/JSON-second parser. Cancellation is checked before loading, after the response and after synchronous parsing. Parsing itself is not preemptible. ParseData.documentURL exposes the final response base without changing stored model layout.

Replace recursive All Books tasks with an iterative loader: reject revisited request/final-response document URLs (ignoring fragments) and bound distinct documents to 16. This bounds navigation requests, not response bytes or every Foundation URL alias. Preserve the existing All Books route and metadata/cover priorities. Support standalone publications and open-access full-book links; buy/borrow/sample-only links do not become full downloads. These are additional destination-consumer repairs, not assertions that the source hotfix already contained them.

## Executed local qualification

Linux x86_64, Swift 6.2.1, Swift 6 language mode, warnings as errors:

- Complete OPDS target: 102 cases passed in Debug and optimized Release, zero failures/skips (93 retained plus nine async/cancellation cases).
- Catalog components: 27 cases passed in Debug and optimized Release, zero failures/skips (16 loader and 11 refresh cases).
- Actual original BookLibrary and catalog-management adapter files were frontend-parsed after their surgical edits; this is not typechecking.
- A mutation control removing only the final publication guard makes the newer-result-wins test fail two assertions, publishing New then Old. This is a mutation-sensitivity check, not an original-main execution claim.

The runners copy complete production declarations and tests unchanged under the actual module names. URLProtocol is the network fixture, not a replacement parser. The catalog runner includes the actual SwiftUI detail view on macOS; Linux explicitly omits that Apple-only file. Its optional --typecheck-ios emits the actual OPDS and selected catalog modules for iOS 15 simulator. Candidate Apple/CI results must be read from the exact published head; no result is presumed here. One initial combined local invocation was interrupted before OPDS Release finished; the separate completed 102-case Release run is the evidence.

    python3 Tests/Portable/run_opds_url_port.py
    python3 Tests/Portable/run_book_catalog_port.py
    python3 Tests/Portable/run_book_catalog_port.py --typecheck-ios

## Remaining gates

This is not a full LakeOfFireReader/BookLibraryViewModel/Realm graph build or interactive SwiftUI test. The catalog runner compiles the actual loading/refresh/model files and, on Apple, the complete detail view; it omits the unrelated file-manager/Realm/navigation portions of the larger views. Full BookLibrary/OPDSCatalogsView composition, minimum host integration, interactive refresh/retry/dismissal and real catalog acquisition remain gates. Verify root Project.swift/Tuist source and test discovery. Existing owning package source directories and test target are retained; no Package.swift change is needed for discovery there.

No root gitlinks, schemas, stored reading identities, original books, dependency requirements, signing, production rollout flags or main/v3-hotfix refs changed. No broad fork merge or #37/#41 composition is claimed. Keep draft until remaining native/app gates are qualified. Root tracking: https://github.com/aehlke/manabi-reader/pull/189.
