# Porting work: OPDS document, search and transport boundaries

This extends #48 beyond its initial URL/model-only increment. Source is still-pending hotfix #45 at `b150e9c71e13f2ae64a729443918a82133fbae74`, not a claim that it is merged or selected by Reader. Destination main is `ac5894d936a15b9d305dafdaeac7afac5a0366dd`; previous implementation `e01d5b160b2c67b30020dfe8b86d2bbd516d137f`; immediate parent `fa68ef51490601de4c0f7f30975e5c0c1f1c5f8f` adds the read-only qualification workflow. Root tracker: https://github.com/aehlke/manabi-reader/pull/189.

## Implemented adaptation

Five production files carry the combined port. Retain main's modular target, public model fields, mutable class ownership, LinkRelation Sendable conformance, sample assets and production Package.swift.

- Scoped Atom root/namespace/direct-child parsing prevents foreign or nested entries, links, titles and authors from becoming catalog structure. Scoped xml:base and final response URLs govern links and author URIs. Preserve descendant text/CDATA, optional category labels, OPDS facet namespaces and OpenSearch counters. Navigation prefers actual catalog links over artwork/auxiliary links.
- OpenSearch handles empty media types, case-insensitive type/parameter names, quoted parameters and scoped XML bases. Protect real template parameters during URL resolution without interpreting escaped literal braces as parameters; preserve optional path parameters.
- Generic/XML/JSON/search fetchers share transport admission. Preserve transport errors; reject non-success HTTP and unsolicited partial documents before parsing valid-looking bodies. JSON standalone publications and nested subject links now use the same final-response HREF normalization.
- Keep #48's existing URL/reference and exact/slash relation-family repairs. This is not a new catalog UI, complete OPDS conformance validator, response-size policy, authentication or redirect-security redesign.

## Swift 6 boundary, not a production downgrade

Main's tools-6.2 manifest defaults to Swift 6. The previous complete module could not compile in that mode because URLSession callbacks captured non-Sendable completions and a mutable Feed.

Network callbacks now explicitly require @Sendable captures; parsed-result callbacks use `(sending ParseData?, Error?) -> Void` to transfer the fresh mutable graph to the receiver without retaining it. OpenSearch snapshots its String self media type before dispatch instead of rereading caller-owned Feed after suspension. No mutable model is retroactively declared unchecked Sendable, and no production warning suppression or language-mode change is introduced.

**This strengthens the public callback's concurrency contract.** Method labels and callback-executor behavior remain, but consumers with unsafe captures may require changes. Passing OPDS tests does not establish compatibility of every SwiftUI/Reader/external consumer. Caller actor hops and generated app composition remain required gates.

## Full-module test composition

93 distinct XCTest methods: all 67 cases from the hotfix module's test set, the 20 prior URL-port methods, and six new concurrency/transfer cases. Existing destination summary projection is retained rather than replaced with the hotfix's older callback test implementation. Source document test files are additive to destination tests; all samples remain unchanged.

Per-test ephemeral URLSessions and stateless URLProtocol fixtures replace global registration/mutable handler slots. Tests execute actual URLSession callbacks, XMLParser, JSON decoding and public model APIs. No live server, fake production parser or source-string assertions. Actor-isolated async XCTest methods avoid the synchronous actor-method discovery cast failure encountered during development.

One prior URL-port expectation intentionally advances with the newly ported contract: standalone JSON's stored href is now absolute, while its existing resolved-URL assertion is retained. This is not an ignored failure or loss of endpoint coverage.

## Executed local evidence

Linux x86_64, Swift 6.2.1, tools 6.2, **Swift 6 language mode**, warnings as errors:

- Full Debug: 93 methods, zero failures/skips; complete-source runner repeated on the uploaded production bytes.
- Full optimized Release: 93 methods, zero failures/skips through the committed runner.
- Exact pre-increment #48 production module, Swift 5 supplemental negative control: 33 document methods produce 29 failures (including two unexpected throws), exit 1.
- Exact unmodified #45 production module, Swift 5 supplemental negative control: the new request-time Feed-type test produces one assertion failure (JSON template instead of the original Atom selection), exit 1. Candidate passes the same assertion.

Repeated configurations are not additional unique cases. Earlier discovery/typecheck failures are not counted as passes or regression proof. The initial CI workflow run 36462568439 deliberately exercises the prior Swift 6 blocker, not this implementation. Ubuntu artifact 10987753856 was downloaded and verified against SHA-256 bc62b205b6db0332a3739f5c1efbb5909ae8fbd8495f423bff03339a14878a14; every retained current/hotfix input matched its Git blob before adaptation. See the live PR for final candidate CI status; no candidate Apple result was available when this document was authored.

Production blobs: OPDS1 c2f1b3b812832628ecbaf2b875e10f46b9b4a9d7; OPDS2 6fc784caa4de70b0bba85f1be535b5d1a1eec03d; models 463d07126529ebbb2deb598ac69d8d35d0df1dba; transport ad4e4708ceaa9d568d43dc4db0d31325ad2665db; URL helper 83b86658ba8526f63bbeb3ddb4af0eeda695a9ef. New concurrency tests 4234623d35ba8b6e598a3f5c6f19c761fba9084e; complete runner 5618b2c3d246758110bdcf2cba1f77d9d71c2d63.

## Reproduce and remaining gates

    python3 Tests/Portable/run_opds_url_port.py

The runner copies every complete production/test file and all sample bytes to a dependency-free SwiftPM graph with the real module name, defaulting to destination Swift 6. It compiles the whole OPDS target, not other Lake targets. CI runs this on Ubuntu/macOS with retained source manifests and logs.

Keep draft until Apple Foundation/XMLParser/URLSession execution, minimum supported Apple targets, actual BookLibrary/OPDSCatalogsView callback consumers, catalog acquisition/search UI and Reader Tuist test discovery/composed dependencies are verified. Preserve #41 and other workers' newer main work; no combined-PR result or root-pin compatibility is inferred. No root gitlinks, production manifest, schema, persisted key, original book, signing, visibility, rollout flag or existing main/v3-hotfix branch changed. Nothing merged.
