# Porting work: OPDS URL and relation contracts on main

Destination: LakeOfFire main ac5894d936a15b9d305dafdaeac7afac5a0366dd.
Source: pending hotfix PR #45, b150e9c71e13f2ae64a729443918a82133fbae74, based on v3-hotfix b6e28d28bcc45949b002d464ca1230a91c66c18b.
Root tracking: https://github.com/aehlke/manabi-reader/pull/189.

**This is a selected forward-port of unmerged hotfix work, not a claim that #45 is already in the Reader-selected hotfix pin.** It changes only two production files on main and preserves the other six complete OPDS source files, all existing tests/resources, main's LinkRelation Sendable conformance, public model shapes and package manifest.

## Ported behavior

Public Link.url(relativeTo:) and parser HREF normalization now use the same resolver. Root-relative and network-path references preserve their intended origins; queries/fragments and existing escapes no longer become path text or double encoding. Japanese IRIs remain usable. Empty references retain the document/query while removing the fragment. Absolute hostless URIs need no base; relative references require an absolute resolved URL.

Public image/acquisition relation predicates accept the exact family URI or a slash subtype, not arbitrary similarly prefixed strings. Stored hrefs, metadata and Hashable identity remain unchanged by URL conversion. This does not add a scheme allowlist, authentication policy or redirect-security boundary.

Source mappings: URLHelper.swift blob 83b86658ba8526f63bbeb3ddb4af0eeda695a9ef (only resolve/isAbsolute/getAbsolute, not the unused template helper); OPDSModels.swift blob 556f1060e9afe66835dccddfaa0f11ece593946b (URL method, relation predicates and obsolete prefix helper removal). The model patch is adapted surgically to main instead of replacing it with the hotfix file. Final model blob 014dc84e686f11508c439aced46c6b2f28318005; URL helper 70f3d4fa5e610323ee7eb11a46814673a6520879.

## Executed tests and language-mode blocker

Original main's complete eight-file module was hash-verified before execution. All 20 new methods compiled and ran against it in Swift 5 mode, producing 32 failed assertions and zero unexpected errors. This is a runtime regression control, not 32 distinct bugs. An earlier overly complex test-array expression failed typechecking; it was simplified before running this control and is not counted as regression evidence.

The candidate passes **27/27 methods in Debug and optimized Release**, zero failures/skips, Linux Swift 6.2.1, warnings as errors, explicit Swift 5 language mode: 20 new URL/model/parser-consumer cases plus all seven unchanged methods in the existing XML/JSON document suites. Whole production files, complete test files and original sample bytes are used; no source extraction, source-text assertions, substitute models or parser stubs. The two existing URLSession/OpenSearch callback test files are not part of this document runner. No network or native UI execution is claimed.

Reproduce the supplemental behavior result:

    python3 Tests/Portable/run_opds_url_port.py --language-mode 5

**Main's manifest uses tools 6.2 and default Swift 6 language mode. The matching Linux Swift 6 module build fails in BOTH original main and candidate**, with the same five existing non-Sendable callback captures:

- OPDS1Parser.swift:36 (completion), :74 (completion), :81 (Feed).
- OPDS2Parser.swift:28 (completion).
- OPDSParser.swift:25 (completion).

The portable runner defaults to Swift 6 and currently exits nonzero on those errors. Passing the explicit Swift 5 probe is not a fix or qualification of main's default build. No production language-mode downgrade, @unchecked Sendable retrofit or suppression was introduced. Apple Foundation and the assembled app build remain untested; these Linux diagnostics do not establish the exact Apple outcome.

Executed new test blob ce857d5563f5bbac02636091447f6f781fc3013f; runner 539c5b43d46798f7d1874f020e488067cc8cba73. Retained tests d9c12ed68a5e00e276ba92b5bff513ea13258746 / f8acd54c61baf16d550fcb74ccb134f350ff05ee and sample hashes 76f99626fd1025f41c2c1249162f058d8bcb3517 / 9e42ab8a18ead2e537f49aac83dc4830ccc8b6bd match main. Repeated configurations do not add unique cases.

## Remaining port and integration work

Keep draft pending destination-language and Apple module/consumer qualification, retained callback tests and actual catalog acquisition/UI validation. Main's existing LakeOfFireOPDSTests directory target discovers the new file; root Tuist/app test discovery is separate.

This bounded patch does NOT port #45's scoped XML parsing, inherited xml:base, OpenSearch MIME/template fixes, HTTP/transport admission, response-URL base changes, callback test isolation or navigation-target selection. Main's XML parser still uses its older acquisition classification; improved public relation predicates are not proof of complete XML navigation repair. Carry the remaining changes through a separately reviewed adaptation that preserves main's destination-specific declarations and resolves the language boundary.

Independent of #41's package/navigation work; no combined-PR qualification is claimed. No root gitlinks, dependencies, schemas, persisted primary keys, original books, signing, visibility or rollout flags changed. Nothing merged.
