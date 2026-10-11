# OPDS URL port checkpoint — 2026-10-11

Source: Lake #50 at 7ba92a8cc3cdd9bc481931fb214856fc751394fe.
Destination reviewed: #138 at 97e1f7b0ec65c4c25ac7d0109e42ae48f659046b.

## Missing behavior carried forward
- Shared URI reference resolution preserves root/network-relative URLs, query and fragment delimiters, percent escapes, empty references and non-ASCII content.
- Link conversion and nested subject metadata use that resolver. Exact OPDS relation families reject lookalike prefixes.
- XML and JSON catalogs resolve against the final response URL. Standalone JSON publications normalize links just like feed entries.
- Preserved current callback entry points; async ownership/transport admission is a separate remaining port.

## Evidence and qualification
- Full current model diff reviewed; retained LinkRelation Sendable and all current model fields.
- Existing LakeOfFireOPDSTests target discovers both test files without manifest changes.
- Twenty existing actual-module URL/model cases carried from #50; three redirected-feed/publication/XML cases added.
- All 23 cases UNRUN. No builds, tests, CI dispatch, dependency pin changes or retired validation systems.
- #50 remains open: HTTP status/partial-document admission, cancellation/Sendable callback ownership, XML namespace/lexical base boundaries, OpenSearch and catalog view integration still require reconciliation. No claim of full OPDS coverage or supersession.
