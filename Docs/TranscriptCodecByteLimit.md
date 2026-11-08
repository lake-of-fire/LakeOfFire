# Bound transcript codec allocations

Main base: a6d6f82b3156b7faaeeb59dce2ae1eb3021cfdf3.
Donor: Lake #113 at 367775198f6b402cb5708896a44469abf788ccd3,
MediaTranscript.swift and ReaderTranscriptDocument.maximumBytes.

Main previously admitted a Zstandard frame's declared uncompressed size up to
Int.max, then allocated that many bytes before decompressing. Core main
ReaderWebMediaCoordinator.existingTranscript calls webVTTString when reusing
persisted transcripts, so a corrupt or oversized stored frame can reach this
allocation. No production crash or malicious input has been reproduced.

This focused port uses the donor's 8 MiB uncompressed-byte policy in a standalone
MediaTranscript.maximumWebVTTBytes constant. Reject oversize encoding inputs and
oversize decoded frame declarations before allocating the output buffer. The
matching encoding bound prevents creating new transcripts the decoder refuses.
Exactly 8 MiB remains accepted. Existing error cases and APIs remain; a new public
constant is additive. No Realm schema, generator version, parser, account fences,
UTF-8 validation, cache mutation or automatic recovery behavior changes.

Compatibility: previously accepted transcripts larger than 8 MiB now throw
contentTooLarge. They are not deleted or migrated. Existing caller error handling
remains; this patch does not promise automatic regeneration or fallback. This is
an allocation bound, not full compressed-input validation or total process-memory
accounting. Compression buffers, copies and caller-retained values remain. The String encoding
wrapper still materializes UTF-8 Data before the Data-level size check.

Ownership: fresh main and donor #113 checked; targeted open PR searches for
MediaTranscript, zstd and transcript compression found no dedicated port.
#529–532 concern handler/registry/parser behavior, not this codec. This bounded
check does not establish the absence of all unpublished work.

Four authored XCTest methods exercise oversized declared frames, oversized
encoding, exact-boundary real-codec round trip, ordinary UTF-8 text and invalid
frame behavior. The frame fixture encodes the Zstandard magic and a single-segment
eight-byte frame-content-size header without a body, requiring early admission
failure. Independent source review found no blocking defect. Oversize fixtures stay close
to the boundary so a regressed implementation does not attempt an Int.max allocation.

All Swift parsing, compilation, typechecking and native tests are UNRUN.
LakeOfFireTests already depends on LakeOfFireContent and discovers this file;
generated Xcode membership and composed app behavior remain unqualified.
No pins, deployment, production changes or denied-operation retries.
