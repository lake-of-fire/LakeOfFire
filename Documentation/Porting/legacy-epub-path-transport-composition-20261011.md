# Legacy EPUB path transport composition — 2026-10-11

Reviewed source: Lake #50 dd9a947b50b59bbe603986fd14ff1676a864d33e; target #138 ed16082de9ed03681456d1ff38958b05253cf198.

## Applied
- Decode percent-encoded entry paths exactly once, per component. Encoded separators cannot become package separators; literal percent-looking filenames retain their literal spelling.
- Encode generated base paths using RFC 3986 unreserved characters, including escaping literal percent.
- Reject duplicate/valueless direct-section and query entry selectors; validate direct/path route origins and compare owner source bytes.
- Preserve current legacy route/processor/cache interfaces and earlier bounded body fixes.

## Evidence and scope
Nine XCTest methods: six path transport cases from #50, two query identity cases, one direct-section selector/origin case. All UNCOMPILED and UNRUN; source review only. No builds, tests, native launches, CI dispatch, dependency pins, or deployments.

This is a bounded partial port. Session-bound routes, owned-snapshot serving, completion-proof processor contracts, sidecar persistence/admission, paired Core producers and progress/schema enrollment remain uncomposed. #50 is not superseded.

Next bounded action: read the completion-proof and sidecar-store changes fully, then compare their producers and consumers against the current Core stack before changing any callback or authority contract.
