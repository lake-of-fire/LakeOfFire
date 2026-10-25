# Native preparation + finish readiness source composition

## Exact graph and status

- Common base358: `294db208af88952b31ed5e9693373cd35f4aed33`, tree `12641b25dc2ce55afd81ff9f0938bec1bb1ee6b4`.
- Native admission377: `4d0e725e67cfd5640ed6bb1bec25ec9a11800e14`, sole parent376 `eaf7ac6821a4e43e43761f74fc66ddbc3a0e4c6e`, tree `1246104022a5fce19c2898f28f78abd74bc4e6a7`.
- Finish readiness379: `88289efaf81bfc9c9e916af05ffd2b7c0e1097f6`, sole parent358, tree `d372264a95ccd0f1ccf80b902d1e09d9ee07f819`.
- Computed composed tree: `f7d5e19bff4da13bbda5051b6620743ff9bf8820`. This is a local deterministic tree hash, not a published commit.

This is team self-review of an explicit composition containing our379. It is not independent approval. There were no remote mutations, test executions, Swift parsing/compiler, native build, browser, generation or CI operations.

## Ownership and required correction

Reopened both exact PRs and their meaningful comments once before composition.377 had no comments.379 had new P2 [5641873471](https://github.com/lake-of-fire/LakeOfFire/pull/379#pullrequestreview-5641873471). Its exact `reconcile-fix-lakeoffire-5641873471` reservation exists; the author explicitly owns the correction. No other composition owner was identified in those comments.

The finding remains in these inputs: the original native commit may suspend before its URL-only synthetic-expectation consumer, then consume the same-URL expectation installed by a newer render while the old document remains current. Its queued finish may then capture the newer UUID and complete prematurely.377's original document/source admission does not retire that still-current document, and379's finish-only identity capture cannot recover the lost boundary. We have not changed or duplicated that active repair. This composition is therefore source/fixture evidence with an explicit required corrective gate, not complete readiness qualification.

## Merge and manual resolution

All three production files merged without conflicts. The composed Mode preserves379's typed UUID fence, pre-dispatch gate, new-UUID issue-marker reset and strict pending expectation. It also preserves377's additive internal commit entry, original source/document predicate, post-await checks and font predicate.377's complete ReaderContent captured-admission implementation and ReaderWebView event-handler call are byte-identical in the composition. Its full HTML fixture, including the corrected three-argument font override, is also byte-identical.

Git reported one textual callback-fixture conflict in cleanup. The merge also silently duplicated `fontCount`, `fontGate` and `fontEntered`; its two font branches would have let379's argument detector bypass377's `failFont` control. The explicit fixture resolution keeps one property set and one font branch, classifies the real `fontCSSBase64` and `stylesheetURLTemplate` arguments, preserves `failFont`, keeps pagination success/error controls, and releases both font and pagination gates. Both production font dispatch sites supply those arguments (Mode2052 and2238). The remaining fixture additions are combined without changing test bodies: snippet setup defaultsfalse, real held/dispatched rendering, isolated stores, cancellation and joined cleanup.

This is a collaborator composition correction, not a duplicate implementation state machine. The raw merge and `fixture-resolution.patch` retain the exact reconciliation evidence.

## Preservation and executed artifact checks

- Callback methods: base #358: 27; #377: 40; #379: 36; composition: 49. Every input method body is byte-identical in the final union, preserving all 13 new #376/#377 methods and all nine #379 methods.
- HTML methods: 34; all method bodies and the entire377 HTML file are byte-identical.
- Complete recursive trees are untruncated with 571 leaves each. Independent Git object reconstruction reproduces all three published input tree hashes, then computes the composed tree from all inherited leaves/modes.
- Changed scope is five paths over358/379 and two paths over377. All other complete-tree leaves are preserved.
- Four strict Git patch batches passed forward checks/application with byte equality and reverse checks/application back to exact input bytes:358→377,358→379,377→composition and379→composition. Whitespace diagnostics are empty. These are artifact checks, not behavior tests.
- **All 83 native methods are authored, uncompiled and unrun in this composition.** No pass from either input is transferred.

See `manifest.json`, `preservation.json`, `strict-roundtrips.json`, `whitespace.json` and the four reconstruction patches. All source inputs were refetched by immutable SHA, saved under `inputs/`, and verified against the returned Git blob hashes.

## API and target source consistency

The unchanged public three-argument Mode entry remains available. The native handler's explicit `documentIsCurrent` label resolves to377's additive internal overload, which forwards the captured predicate to the existing loader-injected entry. Its optional predicate parameter preserves existing direct callers. Both original commit/preparation and379 finish checks use the existing three-argument font helper; the full retained HTML override has that signature. The merged probe's actual bridge argument handling supports both font producers while preserving pagination and failure injection.

Parent Package.swift is unchanged blob `f9183a227e52ae194046cec4ddfca727c1b3c141`. Its LakeOfFireTests path covers both suites and its direct products already include LakeOfFireReader, LakeOfFireContent, SwiftUIWebView, SwiftSoup, RealmSwift and RealmSwiftGaps. No package/source-membership mutation is included.

Root523 was reopened at `4fa2127f0fad4701f4d47a4ccf0df1fcb5987fad`; exact Project.swift remains `eaa06ea01324916d86caabc2cd677bca9aadf360`. Required direct products are present. Coordinator registration remains required for both `Vendor/LakeOfFire/Tests/LakeOfFireTests/ReaderNavigationCallbackLifetimeTests.swift` and `Vendor/LakeOfFire/Tests/LakeOfFireTests/ReaderContentHTMLLifetimeTests.swift`. No historical 130-case evidence input was changed or requalified by this root revision.

377's declared paired Core1002/Common454, captured-import353, Gaps7 and title344/967 prerequisites remain carried-forward integration gates; this bounded composition does not independently requalify their full graphs or native behavior. No root pin or generated project is modified.

## Next action

Root can review these exact local bytes and decide evidence publication. Preserve the active5641873471 corrective ownership. Once that owner publishes, the final integration must retain its capture-before-first-await correction together with this source union and its actual new regressions. Do not present this frozen graph as having repaired that known P2.
