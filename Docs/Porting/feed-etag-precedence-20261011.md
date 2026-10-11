# Feed entity-tag precedence forward port — 2026-10-11

Base: Lake #158 `f96320588e510ca24d4e986d619da444e95c8469`.
Hotfix donor: `6d56a8b9cbb8c4a62c061708024ef30b109d4744`.

Fresh source comparison found a small missing hotfix behavior in `isFeedUnchanged`.
Main accepted a matching entity tag, but on a mismatch fell through to Last-Modified.
When a publisher changed its entity tag without advancing its coarse timestamp (or
moved the date backwards), the successful HEAD path could skip GET and miss new
feed content. Hotfix already returns the entity-tag comparison when both tags exist.

Port that exact precedence rule. Preserve date fallback when either tag is absent,
the existing literal tag comparison, request construction, explicit 304 handling,
main synchronous parsing, lease admission and persistence. This is not a general
HTTP caching rewrite. RFC 9110 §13.1.3 corroborates entity-tag precedence:
https://www.rfc-editor.org/rfc/rfc9110.html#section-13.1.3

The metadata value type and shipped predicate are module-internal rather than
file-private solely so the existing LakeOfFireTests target can exercise the actual
decision. No public API or schema change. Five regression methods cover a changed
tag with equal/older dates, matching tags, missing-tag date fallback, newer dates,
and absent validators.

Validation: source/caller/SwiftPM target inspection and remote byte-readback.
Tests are UNCOMPILED and UNRUN under the existing execution hold. No build,
test, app launch, generation or CI dispatch. No merge, deployment or root pins.
Do not transfer hotfix validation claims to this candidate.

Still separate: feed URL provenance for cached validators/refresh receipts;
HEAD/GET representation changes and validator merging; native dependency-tuple
qualification. This patch does not close those broader gaps or the older Lake #50.
