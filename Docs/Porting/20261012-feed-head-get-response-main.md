# Feed HEAD fallback and GET validator ownership — 2026-10-12

Base: Lake #163 `eb5640283723bb08f8e2f0e65123b0695ccc66bc`.
Sibling #160 `d03fc8fb3f25515004d33f5bf17c84f527125643` remains separate and must be composed: its entity-tag precedence predicate and regression file are not duplicated or changed here.

## Corroborated source findings

At the base, `Sources/LakeOfFireContent/Feeds/Feed Models.swift:1378` rejects HEAD 405/501 before GET. `Feed.fetch(realmConfiguration:)` at line 1823 propagates that failure; both the reader convenience fetch and the library metadata refresh use that path. A resource that rejects HEAD but serves GET therefore cannot refresh.

At base line 1410, GET metadata fills absent validators from the earlier HEAD response. A publisher can change representation between those requests: HEAD describes A, GET returns B without a tag (or without a date), and A's validator is incorrectly associated with B. At base lines 1473–1474, persistence additionally preserves prior validators whenever the supplied field is absent, even after replacing the stored body. A later refresh can consequently compare against a representation never stored.

RFC 9110 sections [9.3.2](https://www.rfc-editor.org/rfc/rfc9110.html#section-9.3.2), [15.5.6](https://www.rfc-editor.org/rfc/rfc9110.html#section-15.5.6), and [15.6.2](https://www.rfc-editor.org/rfc/rfc9110.html#section-15.6.2) describe HEAD metadata and method rejection. The fallback and cross-response validator diagnosis are source-based client behavior findings; no live publisher reproduction is claimed.

## Repair

Allow conditional GET after HEAD 405/501 only. Other status and transport failures retain their existing behavior. Parse validators from GET alone; remove the now-unused cross-response merge. When a successfully parsed and persisted RSS/Atom body replaces the representation, replace both stored validators, including clearing absent ones. For not-modified results, retain omitted stored validators while applying supplied ones.

Existing expected-URL checks, refresh-lease admission, parse/persistence ordering, transaction ownership, and cancellation fences are unchanged. No schema, dependency pin, media/transcript, hotfix checkout, merge, deployment or generation changes.

## Qualification

Six added owning-target regression methods in `AsahiFeedReadabilityPipelineTests.swift` exercise real `Feed.fetch`, intercepted HEAD/GET, entry persistence, and stored metadata: 405/501 fallback; missing and partial GET validators; HEAD-to-GET changed response; GET/HEAD 304; terminal HEAD authorization and GET failures. Existing empty-cache 304 recovery regression remains intact. The new helper reuses the existing private URLProtocol and storage/session setup; no production test API is introduced.

Source review and `git diff --check` only. All added sources are **UNCOMPILED/UNRUN** under the execution hold. No native builds/tests, app launches, CI dispatch or live-network test. Runtime/dependency-tuple qualification and sibling #160 composition remain outstanding. Sync-driven URL provenance and already-stale persisted validators remain separate work.
