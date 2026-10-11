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

## XML and OpenSearch continuation — 07:14 UTC
- Ported the #50 namespace-aware Atom parser, per-element XML base handling, scoped entry/author state, CDATA retention, namespaced counters/facets, exact acquisition classification and catalog-first navigation.
- Ported OpenSearch root/namespace/direct-child admission, lexical base resolution, template placeholder protection and quoted media-type parsing. Empty media types no longer index an empty array.
- Existing callback signatures are retained; OpenSearch snapshots the self media type before the network callback and uses the final response URL. Shared HTTP admission and async/cancellation ownership are still pending.
- Added 33 original actual-module document-boundary cases and the 11 pure search-document cases from the mixed #50 transport/search suite. The seven transport cases are deliberately not declared ported.
- All 67 URL/redirect/document/search cases are UNRUN. Source review only, no native execution.

## Transport admission continuation — 07:17 UTC
- Composed #50's common HTTP validator into all four existing callback fetch paths (generic, XML, JSON and OpenSearch), retaining their existing signatures and executor behavior.
- Reject non-2xx and unsolicited 206 partial documents before parsing, propagate transport errors even alongside data, and preserve the original HTTP error for OpenSearch.
- Five actual-module validator cases ported, all UNRUN. Total 72 focused cases are present across this OPDS composition.
- Async cancellation and Sendable/sending callback ownership are still pending along with URLSession-injected fetch regressions and catalog UI integration. No claim of current native or network qualification.
