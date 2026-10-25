# Captured native commit admission over the published 377/379 composition

This is source compatibility evidence and team self-review for [Lake380](https://github.com/lake-of-fire/LakeOfFire/pull/380), correcting [P2 5641873471](https://github.com/lake-of-fire/LakeOfFire/pull/379#pullrequestreview-5641873471). All 92 combined native test methods remain authored, uncompiled and unrun. Artifact checks below are not native behavior qualification or independent approval.

## Exact inputs

The base is the other author's published composition `e9113c6d34fb81ae2648beeabc0f302974b2a366`, documented in [379 comment 6394625845](https://github.com/lake-of-fire/LakeOfFire/pull/379#issuecomment-6394625845). It already combines native document/source admission377 `4d0e725e67cfd5640ed6bb1bec25ec9a11800e14` and finish readiness379 `88289efaf81bfc9c9e916af05ffd2b7c0e1097f6`, retaining377's376 prerequisite. Its full tree is `b21d312fc019cd5f0daf7c743407b560b5cfcad3`.

Only the three-file correction from380 `8c81376f38212b9bc1cfa63c1c994500cd6d58a3` is reanchored here. That correction's sole parent is379. No source from the earlier provisional local union is substituted for the author's e911 base. The inherited author's evidence records the then-open P2; this directory records its subsequent380 correction.

## Reanchoring recipe and retained behavior

Use e911 as the current side,379 as the common side, and380 as the corrective side for the three changed paths. The textual merge has two Mode conflicts, one native-handler conflict, and two callback-fixture conflicts. Resolve them as follows:

1. Keep377's original `documentIsCurrent` predicate and380's typed `ReaderModeCommitRenderAdmission` together. The native context captures the render receipt synchronously at construction, before Reader content or commit work can suspend. Its Mode call passes both the original context predicate and that captured receipt.
2. Retain the public three-argument Mode entry and the render-admission entry. Extend the existing document-aware entry with an optional render receipt; resolve an omitted receipt at that wrapper's entry before its first await. Forward both values to the loader-injected driver. The driver's fallback remains for direct callers of that internal API.
3. Keep document/selection checks and the persistent render-allocation and issue revisions in the same admission closure, including rechecks after synchronous predicates. Retain377's guard before `readerModeLoading`, its guarded font call, and all379 finish ownership/active-to-completed handoff checks. Retain380's issued-document classification and canonical HTML preservation when readiness completes during a commit await.
4. Deduplicate shared font and pagination fields in the callback probe. Keep one font branch recognizing both actual `fontCSSBase64` and `stylesheetURLTemplate` arguments, preserve both failure controls, use the actual pagination assignment, and release both gates before joining fixture work. Keep all49 author-composition and45 standalone380 test bodies unchanged.

The final callback suite contains58 distinct methods: the union of those49 and45 methods. The complete34-method HTML file remains byte-identical to377, including its three-argument font override. ReaderContent's captured source admission also remains byte-identical to377. No helper is replaced with a test-only production model.

## Executed source and artifact checks

- Verified immutable input blobs; reconstructed the complete581-leaf e911 tree to its published hash.
- Confirmed exactly three source/test paths change over e911, with every other inherited leaf preserved. The resulting tree before this new evidence directory is `e3c6343cd2f92b458c6e3aeb225685ebd8e17245`.
- Applied the reanchored patch in a fresh sparse copy using strict Git forward check/application, verified exact output bytes, then strictly reversed it and verified the original bytes. Whitespace diagnostics were empty.
- Compared every input callback test body textually against the58-method union; all are byte-identical and names are unique. Verified the entire HTML fixture and its34 method bodies are unchanged. These comparisons establish source preservation only.
- Read the combined native context, wrappers, driver, font predicate, finish ownership and fixture cleanup. API labels resolve within the existing LakeOfFireReader module; no new exported dependency or module edge is introduced. The source correction remains inside the same two production files and callback suite as380.

`manifest.json` records the exact file hashes, inputs, artifact results and execution limits. No Swift parser, compiler, native runtime, browser, generation or CI was invoked. No pass from any parent or prior composition is transferred to these bytes.

## Integration gates

The unchanged Package.swift blob `f9183a227e52ae194046cec4ddfca727c1b3c141` includes both suites in LakeOfFireTests and supplies their direct module dependencies. The root integration snapshot reviewed here is523 `4fa2127f0fad4701f4d47a4ccf0df1fcb5987fad`, Project.swift `eaa06ea01324916d86caabc2cd677bca9aadf360`. Its required direct products are present, but it still needs coordinator registration for `Vendor/LakeOfFire/Tests/LakeOfFireTests/ReaderNavigationCallbackLifetimeTests.swift` and `Vendor/LakeOfFire/Tests/LakeOfFireTests/ReaderContentHTMLLifetimeTests.swift`.

377's declared Core1002/Common454, captured-import353, Gaps7 and title344/967 companion qualification remains an integration gate. This bounded source composition does not select those proposals as root pins or independently qualify their complete graphs. Root dependency pins and generated projects are unchanged. Authorized native compilation/execution of the final integrated revision is still required.
