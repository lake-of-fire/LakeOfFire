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
