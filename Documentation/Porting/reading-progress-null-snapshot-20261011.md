# Reading-progress null page snapshot compatibility — 2026-10-11

## Exact-head finding
Reviewed #50 a3984f5c41562f598d131e6005e4d9f78540bc58 and current-main composition #138 27a4bc463d05129c1335416e0c1046d6df348ce7. Both ebook-viewer.js producers explicitly pass null for unavailable currentPageNumber/totalPages and forward those keys unchanged to updateReadingProgress. The stricter #50 FractionalCompletionMessage decoder rejected every NSNull optional integer. Therefore an otherwise valid position could be discarded whenever a page snapshot was unavailable, including the known-blank-viewport case.

This is a source-correlated defect, not a reproduced native runtime result.

## Repair
Optional integer keys treat JSON null as absence, consistent with the producer and the prior reader behavior. Malformed present values still fail closed: booleans, numeric strings, negative/fractional/nonfinite values and numbers outside JavaScript's exact integer range. Required fraction, booleans, document provenance and restore-success checks are unchanged.

Two behavioral tests cover a JSON roundtrip with null optional fields and known-blank viewport preservation with absent page information while malformed counts remain rejected. The existing invalid-value test now distinguishes null absence from malformed values.

## Qualification
All tests are UNCOMPILED/UNRUN for this change. No builds, native launches, project generation, CI dispatch or dependency selection changes. Earlier historical workflow passes do not qualify this new head.

## Next
Carry the same compatibility repair when composing strict payload decoding into newer main; never copy the older null-rejecting decoder unchanged.
