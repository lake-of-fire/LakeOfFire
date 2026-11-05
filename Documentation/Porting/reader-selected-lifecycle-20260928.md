# Porting work: preserve Reader-selected Lake lifecycle hardening on main

Destination Lake main: ac5894d936a15b9d305dafdaeac7afac5a0366dd.
Reader main currently selects Lake 269f26450fa565326c6031e43da51211a7b2b67c. That selected revision contains two correctness commits absent from Lake main:

- 638b79e3efe7c72ecd62f9f94b6e49c43c1a19fb — Harden reader and file lifecycle.
- 269f26450fa565326c6031e43da51211a7b2b67c — Preserve reviewed reader correctness and runtime parity.

Lake main has one commit absent from the Reader-selected line: ac5894d936a15b9d305dafdaeac7afac5a0366dd, the SwiftSoup source-reuse serializer migration. This port keeps it.

## Three-way rule

All Reader-selected changed paths are carried byte-for-byte except ReaderEbookTextProcessor.swift. That file combines the selected lifecycle/completion-proof implementation with Lake main's newer outerHtmlUTF8ReusingSourceOutsideBody serializer API. No regression back to outerHtmlUTF8FromCurrentTreeSplicingBody is allowed.

The selected lifecycle changes include generation-fenced file inventory refresh and orphan deletion, bounded process-text request bodies, package-capability source checks, processed-payload admission, strict WebKit scalar decoding, website-data-store/pool lifecycle corrections, native lookup publication generations, sidecar retention and associated regression tests.

This PR exists because a root-selected dependency can be ahead of the submodule repository's main branch. Any later v3-hotfix-to-main integration must compose these Reader-selected commits rather than qualifying only against Lake main.

## Qualification boundary

The accompanying workflow executes the two complete JavaScript regression files and frontend-parses the changed Swift production files on macOS. The existing native XCTest files are preserved but full package/app qualification remains separate because Lake uses sibling path dependencies in the full graph. Compose this PR with the larger #50 integration and run its native matrices before a Reader gitlink change.

No Reader root pin, schema, historical key, original user file, signing, rollout flag or production CloudKit setting changes here.
