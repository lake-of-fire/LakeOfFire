# Book runtime handoff and stale-event revocation — October 7

## Exact scope

Follow-up to merged Lake #116 head `1f06eb5ebfe27d37cc6f73f2fc28bcc8e5190e31`.
Publication starts from its normal merge `57a7f9525b8b975b74689b81d1e73c762de2556e`,
whose complete tree is identical to that inspected head. No existing branch is overwritten.
The inspected original runtime is Git blob `6dc2f5680fe2df30821e5cd0aded22a7603d5e51`.
The previously published Endcap, state controller, action bridge and native contracts
are retained. One production module changes: `book-reading-runtime.js` (+107/-52).
Three existing browser runners add the runtime's existing page-turn helper to their
no-network module bundles; no assertions, rosters or timeouts change. Three additive
regression/browser files and this report complete the eight-path patch.

The component workspace contains the complete seven relevant production modules,
not extracted runtime functions. It is a retained selection, not a complete Lake
checkout. All changes were prepared in an isolated container, not the user's checkout.

## Reproduced defects

### Captured events could borrow recovered scope values

The runtime checked a scope receipt's map membership before renderer lookups. Those
callbacks could invalidate the display and publish the same native scope values.
Comparison then returned true using the successor even though the original receipt
had been retired. An event capture could similarly acquire a new account or page
selected during its own document or URL lookup.

Capture now retains the existing account, observation, revision and scope-map
identities. Validation rechecks the original membership after all key/renderer
comparisons. Event capture records its original renderer and revision rather than
sampling replacements at return. There is no new token, counter, timer or registry.
A normal same-pass refresh without invalidation still preserves live receipts.

### A loading gap left old Book Actions ready

When renderer contents became empty, hidden-only, or unavailable, both the selected
and observed documents could be null. Equality between those null values made the
previous chapter context appear current. `ready` is now false without a displayed
chapter; the legitimate End of Book shell remains supported without a chapter.
A new displayed document can publish normally, and old receipts stay retired.
These cases use ordinary empty/hidden contents, not reentrant getters.

### Frame cleanup could strand the publication or overwrite new rendering

A throwing outgoing/hidden frame callback stopped sibling invalidation, shell
readiness updates or runtime closure. At the end page this could leave the actual
publication inert with its control still attached. Frame revocation now resolves
its callback once, checks the original owner before invocation, and contains
failure. Token fallback is permitted only while that original owner remains current.
Runtime cleanup phases are independent; one failed observer cannot stop teardown.

An active-frame scope setter or projector lookup could also publish a newer sample
before the older projector ran. The original publication predicate is rechecked
at both edges. Active projection exceptions and non-callable installed projectors
remain errors: this repair does not turn failed active rendering into acceptance.

### Document handoff and navigation needed final ownership checks

One observation record replaces the separate observed-document/renderer variables.
A replacement is selected before outgoing cleanup, and the continuation verifies
that both the observation and location revision survived that callback. A nested
replacement cannot be cleared by a redundant older relocation.

Book navigation retains its original account, renderer, book and dispatch revision
through spine and method lookups. It rechecks them before physical movement.
After the await, it permits legitimate movement to a different document/revision,
but still rejects a retired host. Explicit renderer supersession uses the existing
page-turn disposition helper and remains superseded, not a retryable failure that
would offer another pull-back. Genuine no-move failure remains retryable.

## Executed verification

Node 22.16.0 and installed Chromium 144.0.7559.96 in Linux:

| Exact selection | Result |
| --- | --- |
| 45 new + 283 unchanged Node cases, concurrency one | 328 passed |
| Same selection, JIT disabled / concurrency one | Same 328 passed |
| Same selection, reversed file order / concurrency four | Same 328 passed |
| Original complete runtime, same 45 new cases | 39 failures reproduced; six controls pass |
| New real-DOM browser cases | 30 passed |
| Inherited Endcap/state/integrity/settlement browser cases | 22 / 16 / 17 / 18 passed |
| Original runtime, same 30 browser cases | 28 failures reproduced; two controls pass |

Every final positive case completes with zero failures, skips or cancellations.
Browser comparisons have zero page-script or harness errors. Browser tests execute
real DOM, iframe Documents, accessibility state and actual button clicks. Native
endpoints, Core frame projection and the paginator interface are explicit controlled
collaborators. Reentrant getters and throwing host hooks are deliberate failure
injection, not attribution of an observed customer incident.

Ten independent, syntax-valid partial reversions execute the same 45-case roster
and reproduce respectively 3 / 1 / 2 / 1 / 1 / 2 / 1 / 4 / 2 / 1 failures. These
cover missing-display admission, callback lookup, active projection, fallback
revocation, observation ownership, scope capture, receipt comparison, dispatch
revalidation, superseded movement and independent teardown.

The initial candidate fixed the frame/navigation cases but still failed eight newly
added receipt-capture/validation histories. Those failures led to the second repair.
One early fixture recursively spread an object with its own injected getter; that
fixture error was corrected without weakening the intended stale-dispatch assertion.
A fault-control pass also exposed missing coverage for a wrapped scope comparison;
its added behavior test independently distinguishes the final receipt check.
All those intermediate logs are retained separately and are not counted as final
passing or negative-control evidence.

Two aggregate browser verifier invocations hit their outer container limits. They
are incomplete evidence, not passing runs. Final verification uses file-backed
streams and six separately bounded browser groups; each group completed with exit
zero and a finalized receipt. The original-source group expects its reproduced
behavior failures, not a positive application result. No owned test process remains
running after verification.

The final harness review corrected module ordering to retain the existing explicit
`--state-source` override. Default and explicit-current controller runs each pass
all 16 inherited browser cases; the original controller still reproduces its 13
failures using that same override. A preceding attempt with a missing fixture path
failed before browser execution and is retained as setup failure, not a test result.

## Reproduction

From a complete Lake checkout:

```sh
node --unhandled-rejections=strict --test --test-concurrency=1 Tests/JavaScript/book-runtime-boundaries.test.mjs
python3 Tests/Browser/BookRuntimeBoundaries/run.py --output /tmp/book-runtime-handoff.json
```

The browser runner requires installed Python Playwright and Chromium. It makes no
network requests and refuses an existing output file. `--runtime-source` selects an
explicit original/fault source without altering the checkout. The conversation
packet includes the complete retained inputs, original runtime, fault variants,
ordered case rosters, per-process logs and a bounded multi-phase verifier.

## Acceptance boundary

Keep this follow-up draft. This is not a complete current Lake/Core workflow, real
Realm/CloudKit/WKWebView, full Foliate paginator or assembled Reader/iOS qualification.
It does not replace the independent source-scoped acceptance of merged #115.
No Reader dependency pin, generated project, qualification ledger, native mutation
policy, protected branch, release authorization or Codex task is changed here.
