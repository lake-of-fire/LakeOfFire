# Transcript cue metadata boundaries

This focused main adaptation fixes dropped cue identifiers beginning with NOTE,
STYLE or WEBVTT. Main's broad prefix rejection discarded these cue blocks before
examining their timing line. Match NOTE and WEBVTT only at end-of-line, space or
tab boundaries, and STYLE only as a complete first line (allowing trailing whitespace).

Donor evidence: Lake #113, head 367775198f6b402cb5708896a44469abf788ccd3,
ReaderTranscriptDocument.swift line 57 uses delimited NOTE and exact STYLE.
Main base: a6d6f82b3156b7faaeeb59dce2ae1eb3021cfdf3.

This is not a transplant of the donor parser. Existing block trimming, header
handling within the block parser, timing parsing, text extraction, raw WebVTT,
HTML escaping, registry behavior and public APIs remain unchanged. This does
not add REGION support or strict document admission. Header-like identifiers
with a WEBVTT space/tab suffix remain treated as headers, preserving the
existing behavior rather than introducing a new header-position policy.

Ownership: inspected current #113 and main draft #529 (request lifetime),
#530 (route identity), and #531 (language). These scopes do not implement cue
keyword recognition. Targeted open-PR searches found no dedicated duplicate.
This is a bounded ownership check, not a claim that every private worktree is
known. The production hunk is separate from those drafts and the unpublished
entity-decoding candidate. No root pins or other branches are modified.

Four XCTest methods cover keyword-prefix identifiers, NOTE comments, header
and STYLE block exclusion, CRLF normalization and factory raw-VTT preservation.
They call the production parser/factory. All Swift parsing, typechecking,
compilation and test execution are UNRUN. SwiftPM's LakeOfFireTests target
already depends on LakeOfFireContent and discovers the new file; generated
Xcode test membership and mounted app integration remain unqualified.
