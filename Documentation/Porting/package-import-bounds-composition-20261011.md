# Package bounds and import presentation composition

Reviewed 2026-10-11 07:59 UTC. Source: Lake #50 at ce8200d810d35b6ff18e0da2fe33341e5d87b73b. Destination: #138 at 1252ef21242b5e0107c8fbc08db3ff497e68cd6d, tree fd51c8e2c55a8db6189b006c678e9943d9ace306.

## Reviewed and composed
- Compared all 37 Archive+Data.swift change regions; carried resource bounds, cancellation and extraction integrity checks while preserving current descriptor/root identity checks, exact path admission and archive fingerprint verification.
- ReaderPackageEntrySourceError already existed in the destination Archive+Data.swift. The missing prerequisite was its additional resource/integrity cases and bounded implementation, not a missing type or separate file.
- ZIP advertised count and catalog entry/path/aggregate budgets reject oversized inspection. Both ZIP and directory reads validate advertised and actual bytes. ZIP reads verify CRC and output size; directory growth is checked at read time. Enumeration fails closed on filesystem errors.
- Added shared import operation/result/presentation helpers. Cancellation remains quiet and never deletes an already committed import; nil import results and typed package failures are actionable.
- Imported 11 actual package-source regression methods and added three primitive budget/accumulator cases for rejection without mutation, UInt64 overflow and negative limit clamping. Imported 13 import-boundary cases. All 27 methods are authored but UNCOMPILED and UNRUN.

## Deliberately incomplete
- Import helpers are prerequisites; Books and generic file-picker UI are not routed through them in this commit. Book selection/download ownership, navigator shouldLoad admission and UI composition remain the next bounded action.
- Metadata-specific read limits and full EPUB serving/storage/restore composition remain separate. This does not supersede #50 or qualify its entire file list.
- No build, test, benchmark, native launch, CI dispatch, dependency selection, schema bump or production change. Existing workers checked completed before editing. No retired validation files restored.

## Book row and selection continuation — 08:02 UTC
- Composed the #50 explicit-selection coordinator and passive import owner into current BookLibraryViewModel and book list rows, including today's reentrant-start, weak lifetime and passive/explicit cross-owner repairs.
- Retained the current Publication declaration and all OPDS refresh/pagination changes. Current unrelated library loading/deletion/layout and BookGridCell remain untouched.
- Routed the Books file picker through shared import presentation. The exported generic helper is present; adoption by external app call sites remains separate.
- Navigator load accepts an optional admission callback and checks it before work, after both suspension boundaries, before reader-mode effects and before issuing the request. Existing default callers retain their prior behavior.
- Four suites carry 12 coordinator, 15 passive owner, 17 import-state and 8 actual view-model stage cases (52 methods), all UNCOMPILED/UNRUN. These are source regression fixtures, not proof of mounted UI or actual native navigation execution.
- BookGridCell download/import identity and serving/storage/restore remain open #50 reconciliation. Current primitive bounds/import suite adds 27 methods separately; no whole-stack closure claimed.
