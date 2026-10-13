# EPUB package-source admission composition — 2026-10-11

Reviewed Lake #138 at 1aa74a32d0d490934f57b629027d9108612d423c against older #50 a3984f5c41562f598d131e6005e4d9f78540bc58.

## Missing behavior now composed
The newer handler trusted an X-Ebook-Source-URL header ahead of the requesting main document. This could rebind a resource request to another package. The port extracts the older package admission functions into EbookPackageCapability.swift and uses them at /entries, /entry, /entry-source, /process-text and /processed-section admission.

Every present source identity must be valid and agree: header, query, main-document owner and any route-derived expected source. Duplicate source selectors, including valueless selectors, are rejected rather than filtered away. Package identities reject relative URLs, credentials and ports. Query/fragment decorations are removed. A processed-section document resolves to its physical package owner. Only direct top-level processed-section admission permits a missing main document; a header alone cannot create ordinary resource ownership. Process-text content location must agree with the admitted package.

The current two-argument text processor, cache interfaces, path transport and bounded request-body implementation are preserved.

## Evidence and limitations
EbookPackageCapabilityPortTests contains seven XCTest methods: four carried older admission cases and three additional owner/credential cases. This is static source review only. All seven tests are UNCOMPILED/UNRUN; no native host, build, generation, test or CI dispatch was started.

This closes one admission gap, not the complete EPUB port. It does not activate owned snapshots, serving-session access receipts, single-use completion proof, sidecar retention/leases or final runtime/dictionary publication fences. Those require a compatible paired Core producer and lifecycle composition. No dependency selections changed, and #50 is not superseded by this partial port.

## Next bounded action
Register this regression file in the root Tuist test source list, then continue the paired completion-proof/cache producer review before changing callback signatures.
