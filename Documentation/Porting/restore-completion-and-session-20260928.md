# Porting work: validated restore completion and package-session preservation

This is a follow-up to the v3-hotfix restore/continuation adaptations, based on
Lake #41 at `9b46ac6cce7694e66cbe8f5ebf63e10572b85a4e`. It fixes gaps in the
previous port, not a blanket merge of the hotfix or the identity branch.

## Findings and implementation

The loader validated its terminal receipt **after** calling
`completeLastPositionLoad`. That method enables Reader's relocation-persistence
path. A no-throw wrong landing could consequently be reported as failed while
still marking the reader restored, running success effects and preventing an
identical retry through `duplicate-ready`.

Validation now precedes completion and every success-only effect. A new restore
closes the previous reader success gate before navigation. A typed validation
failure preserves the measured snapshot: the correlated receipt still correctly
reports `navigationOk: true` and `restoreSatisfied: false`, rather than pretending
that navigation threw. Failed attempts keep the reader available for host error
handling, do not qualify as duplicate-ready, and release their foreground token.
Direct restore callers receive a rejection for an unsatisfied target.

A direct restore also supersedes initial-request deduplication. Cleanup ownership
is distinct from renderer validity: replacing a renderer revokes navigation but
does not strand the old restore flag; a newer restore's flags remain untouched.
Explicitly non-applied default navigation/fallback cannot open the saving gate.

Malformed supplied initial requests reject before changing presentation or
retiring a valid active reader. Valid explicit zero fractions now remain targets
through JavaScript normalization and navigation. A CFI with a historical zero
companion fraction keeps CFI priority. Missing position remains
on the existing default-opening route. Only the preexisting zero-classification
expectation changes; retained success, cancellation and ownership tests remain.
**This does not change main's native saved-position loader/bridge, which still
needs its separately scoped zero-position and strict-admission integration.**

## Companion identity boundary

Lake #37 at `7b3f06467c3eb51bb69be3ffd7e852fbaadc3674` passes `packageSessionID`
to `loadEBook`. The extracted loader had dropped it. It now validates and passes
that token to the source factory and includes it in duplicate identity. The
actual immutable source descriptor travels unchanged to Reader.open and cache
warming. Distinct tokens at the same URL are distinct loads.

`ebook-native-source-request.js` is copied byte-for-byte from #37, blob
`ddfd7b18636883550a9b4b8d006df7dbbdffd42a`, rather than introducing a divergent
normalizer. A factory that discards or changes an explicit token rejects before
replacing the current reader. In **this standalone port**, the viewer's existing
legacy factory cannot serve a bound session and therefore rejects that explicit
input instead of silently falling back to URL access. Ordinary legacy loading
is unchanged. This is not completed bound serving or qualification of combined
#37/#41: preserve #37's factory, native routes, rendition and process-text/media
changes when composing them. No new runtime rollout switch is introduced.

## Verification and boundaries

Local Node 22.16.0 executes all **310** JavaScript cases with zero failures,
cancellations or skips: 286 retained plus 24 new loader/completion/session cases.
One existing zero-classification assertion is intentionally updated. The new
session cases execute the actual companion source factory with the production
loader/resources; Reader construction and browser/native-message endpoints are
still test doubles. These are not actual WebKit layout or durable Realm tests.

Four targeted requirements failed with AssertionError against the exact prior
runtime before passing with the change: wrong landing unlocks completion,
identical retry is discarded, malformed explicit request replaces the reader,
and explicit zero takes the default next-page route. An intermediate test used
a nonexistent fixture method; it was corrected to the real makeReusableSource
API and is not counted as a product defect or regression proof.

Current-head CI status and immutable evidence are recorded in the PR description.
Do not reuse prior native results as qualification of the full new composition.
No schemas, historical keys, original books, root pins, signing, native admission
or production CloudKit state change. Real retry/error presentation, native saved
zero, full envelope/durable-write lifetime, #37 composition and assembled
Common/Core/Reader acceptance remain required.
