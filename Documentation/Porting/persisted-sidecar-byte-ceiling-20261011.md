# Persisted sidecar byte ceiling — 2026-10-11

Source review of #50 dd9a947b50b59bbe603986fd14ff1676a864d33e found that maximumEntryByteCount only guarded insertion. A fresh store configured with a smaller limit still loaded and hashed a larger previously persisted object. Both disk cache lookup and insert's existing-object comparison mapped the entire object before any limit.

The storage read now consumes at most the configured limit plus one detection byte, in 64 KiB chunks, and rejects empty/error/oversized data before hashing. Existing SHA-256 token validation remains. A rejected read does not delete historical bytes. Reinserting known correct bytes can still atomically repair a corrupt content-addressed object. The limit is clamped to 256 MiB, so remaining+1 cannot overflow.

This also carries #50's bounded nonempty insertion rule into the current-main store, without its separate retention/lease/retry-token policy.

Five new owning-target XCTest methods cover empty/oversized insertion, a reopened smaller limit, exact-limit multichunk disk reads after memory eviction, content-address mismatch and reinsertion repair. All UNCOMPILED/UNRUN. No native builds/tests, CI dispatch, pins or deployments.

This does not qualify cross-process retention races, filesystem replacement/symlink ownership, completion-proof APIs or Core producer integration. Those are separate remaining review items. Source review of the full #50 sidecar file and candidate Core configuration confirmed the completion-proof callback is not yet composed in main: current Core uses the two-argument EbookProcessedDocumentPayload closure; #50 requires the per-invocation proof and EbookProcessedSectionPayload. Do not switch that API independently.
