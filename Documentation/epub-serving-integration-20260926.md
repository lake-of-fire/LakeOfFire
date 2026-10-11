# EPUB owned serving integration

## Implemented boundaries

`ReaderEBookServingPackage` discovers the declared selected OPF from a strict, bounded container read, fingerprints the private coordinated snapshot, and constructs the actual package reader from that same file. Entry membership, sizes and decoded bytes are checked against the fingerprint. The descriptor passed to Foliate contains that exact declared OPF path. It is not proof of a legacy locator's historical revision.

`ReaderEBookServingSessionStore` issues one unguessable document capability per lease. Identical content keeps the same persistent file-version token but different document capabilities. The store is per reader, not a global URL-to-latest-revision map. Withdrawal, closure, wrong sources and mismatched generations fail without pathname fallback. A foreign store cannot revoke another store's lease.

The actual `EbookURLSchemeHandler` captures access synchronously before dispatch and carries it to terminal publication. Entries, processed sections and assets use the retained package when bound. Process-text deduplication includes the session; its input still comes from the native viewer. A stable registration detects store replacement and stale legacy work captured before session activation. Replacing a registration does not close a shared store owned by another reader. Legacy operation remains available only to a never-activated store.

ReaderWebView installs its supplied store synchronously before constructing WebKit. The new environment is an integration seam, not automatic Core adoption. JavaScript load, reusable native/cache-warmer sources, entry fetches, direct sections, media assets and both same-URL reuse paths retain the immutable capability. The new `/entry-session/` namespace retains source, resource generation and session separately. URI components decode once; duplicate/valueless selectors are not silently discarded. Media requests retain that URL through blob conversion and cannot publish a late result into a closed or changed element.

`resolveAlreadyReadableEBookURL` uses metadata-only eligibility on the exact active storage root, including unpacked child resources and hidden files. It never invokes the normal download-requesting resolver. Eligibility does not prevent provider eviction between inspection and capture and is not proof of remote inventory completeness. Caller-owned enumeration and revalidation are still required.

## Verification scope

The component runner compiles the actual snapshot/fingerprint/session/rendition/availability code and the actual ReaderPackageEntrySource declaration from Archive+Data.swift, not a decoder double. It deliberately excludes the later app-dependent cache and does not compile the full WebKit handler or ReaderWebView. New full-host EbookServingHandlerTests exercise those real handler boundaries separately; they must be run in the initialized native graph and registered in the root Xcode test target.

Portable request tests and the full JavaScript module test directory are repeatable locally. Node module tests and a supplemental call-site audit do not imply full browser/renderer qualification. Native Foundation snapshot cases remain in the existing fingerprint matrix with the released and production-locked ZIPFoundation revisions.

## Remaining coordinated adoption

Core must enumerate relevant readable copies, acquire packages, call Common's inventory-based prepareOpen before initial restoration/activity, install/retain the requested package lease, supply `.readerEBookPackageSessions(store)` and pass its ID to `loadEBook`. Current Article receipt/producer/Mark/Undo/Finish/restart/clock/presentation/cleanup paths must consistently carry the selected bound Common context while preserving physical source checks and historical attribution. Serving capability alone is not Article mutation authority.

No root pins, schema version, original EPUB bytes, historical reading keys/epochs or CloudKit data were changed here. First creation, conflict/reopen UI, known-edit correspondence, predecessor clients, compatible root composition and native migration/two-client qualification remain separate unfinished work. Do not activate only the serving layer and describe it as automatic progress continuity. Crash-orphan snapshot cleanup remains an explicit bounded maintenance follow-up; ordinary owner/failure/cancellation cleanup is implemented.
