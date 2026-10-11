# Current publication reconciliation — October 7, 2026

The original review below targeted the then-open Lake #116 head. #116 has since
merged. Current `v3-hotfix` was inspected at `b35b079b9df0ddc8de7d4c26bbcc91e8f426c68f`.
Its Book Action bridge still matches the verified preimage
`7212828eef89e2262c4c55c13ec86b0f883fd230`; the runtime has advanced to
`62c1ac0cd4810ec2fb3cf884e0436a8a913920db` with the independently reviewed
Book runtime event/navigation ownership repair.

This publication **preserves that newer runtime architecture** and composes only
the still-missing fixes from this review: Endcap retirement before bridge timer
cleanup, immutable scope receipt keys, independent frame projection/scope copies,
unchanged-scope cleanup fallback, observed-frame cleanup after renderer discard,
and stale visibility suppression. The composed runtime blob is
`a1a758e53d874daf1c2c2e411d6571f719de4192`; the bridge postimage is
`313e3861eac7b460b6c97f2907575437177d6010`.

The BookRuntimeHandoff browser runner includes the runtime's existing
`page-turn-coordination.js` dependency required by the newer source. No behavior
case or assertion was removed or weakened.

Current composed verification in the isolated packet: **312/312 Node cases**
serial, **312/312 JIT-disabled**, **312/312 reversed/concurrency-four**, and
**87/87 Chromium scenarios** across runtime handoff (14), Endcap lifecycle (22),
state transaction (16), action integrity (17), and settlement (18), with zero
page or harness errors. These are selected-module/component checks, not complete
Lake/Core, Realm/CloudKit/WKWebView, full Foliate, or assembled iOS acceptance.

---

# Book runtime frame cleanup, account handoff, and scope receipt review

## Delivery and exact source

This increment is implemented and tested but **not pushed**. It targets LakeOfFire
#116 on `fix/book-endcap-lifecycle-20261007`, inspected at
`1f06eb5ebfe27d37cc6f73f2fc28bcc8e5190e31`. That PR's existing Endcap repair is
retained unchanged. This patch changes two shipping JavaScript files (+116/-44)
and adds four test/browser/report files. No original test assertion is edited.

| Shipping path under foliate-js | Original Git blob | Prepared Git blob |
| --- | --- | --- |
| book-reading-runtime.js | 6dc2f5680fe2df30821e5cd0aded22a7603d5e51 | c1d1dddaf17479ef4009bcd410c469d54f159fbc |
| book-action-bridge.js | 7212828eef89e2262c4c55c13ec86b0f883fd230 | 313e3861eac7b460b6c97f2907575437177d6010 |

Original source was compared with the connected repository. Execution uses the
complete seven retained JavaScript modules, not extracted production functions.
The full repository is not present in this container; this is a selected module
checkout. Browser imports are redirected to data URLs to run without network.

## Findings and repairs

### One broken frame could strand sibling cleanup and End of Book

The original runtime invoked each frame's invalidator directly. A thrown callback
could stop later frame invalidation, accepted shell updates, observed-document
replacement, or `close()`. In the browser, close could leave the end page mounted
and the underlying publication inert. A renderer that had discarded its contents
could also leave its previously observed iframe's exposed scope active.

The existing cleanup helper now isolates each frame, looks up the callback once,
and rechecks the original caller before invoking it. If the callback fails, it
withdraws only an unchanged exposed scope and never clears a replacement scope
installed during reentry. This fallback does not pretend to complete private Core
cache cleanup that failed inside the callback. The known observed document remains
a cleanup target even after the renderer drops its contents. A local Set avoids
calling its invalidator twice within one traversal. Independent runtime owners
still retire when a separate shell invalidator throws.

Only cleanup is contained. Failure of the required active-frame projection still
escapes the publication and is **not** reported as a successful native
acknowledgement. The new suite explicitly retains this distinction.

### Account selection and Endcap retirement were ordered incorrectly

The bridge updated its account and ran timer cleanup before the runtime retired
the Endcap's old activation. Cleanup could synchronously accept a fresh account
sample, after which the older continuation disabled the already-current Endcap.

The bridge has a new optional, synchronous `onAccountChange(stamp)` observer. It
runs after the bridge's private account/request indexes change but before old
timer cleanup. The runtime uses it to retire the Endcap generation at that exact
boundary. Old and new promise outcomes remain independent; the observer can start
a new command or select a later account without old cleanup removing that work.
An observer exception cannot strand the old deliveries. This option is not a wire
field, native mutation token, retry mechanism, or additional account registry.

### Old projection callbacks and location preparation could borrow successors

An active-frame callback getter or scope setter could synchronously accept a newer
projection. The old invocation then called the stale projector, overwriting visible
read coverage. Both operations are now checked against the existing publication
predicate before the next effect.

Outgoing cleanup and location/renderer getters could also relocate and accept a
new sample. The old `updateLocation` then replaced that observation or sent a
redundant newer request. It now captures the existing observation/revision before
selection, prepares the captured URL before changing observed identity, and checks
those same private values after callback-bearing work. The redundant documentURL
helper is removed. No extra lifetime counter or retry queue is added.

### Scope copies could be retargeted or acquire recovered ownership

The previous WeakMap associated a captured scope with only its account. A caller
could edit that defensive copy to a newer pass's values and make it appear current.
A renderer lookup could also invalidate and recover equal values in the middle of
scope verification, letting an earlier receipt acquire the recovered lifetime.

The same WeakMap now retains each receipt's original account and canonical scope
key. Capture and validation recheck the map identity across renderer calls. Copies
remain mutable for compatibility, but edits cannot change their private receipt.
Ordinary successful same-pass refreshes still preserve genuine receipts; failed
refresh/account retirement does not. Page-event validation also rechecks its
original position after scope observation. This map remains weak and is not a
persistent event registry or native mutation capability.

### Frame inputs aliased shell projection and exposed scope

The visible frame callback received the same projection used later by the shell,
and its scope object was also exposed on the frame. Synchronous or retained edits
could promote shell Finished or change the selected frame scope without a native
publication. The runtime now supplies independent shallow field/array/scope copies
for that flat validated projection. The exposed scope is separate too. This adds
no new JSON serialization, deep graph traversal, or DOM-derived reading model.

## Review iterations and executed evidence

Node 22.16.0 and Chromium 144.0.7559.96 on Linux. These are controlled
counterexamples, not attribution of a reported production/customer incident.

| Final selection | Result |
| --- | --- |
| 29 new plus 283 unchanged Node cases, explicit serial | 312 passed; no failures, skips, cancellations |
| Same cases with JIT disabled | Same 312 passed |
| Same cases, reversed files and concurrency four | Same 312 passed |
| Same new Node cases, original runtime and bridge | 27 failures reproduced / 29 cases |
| New real-DOM browser cases | 14 passed |
| Inherited Endcap / state / integrity / settlement browser selections | 22 / 16 / 17 / 18 passed |
| Same new browser cases, original runtime and bridge | 13 failures reproduced / 14 cases |

The browser union is 87 scenarios; repeated engine/configuration runs are not
additional unique cases. Both positive and negative browser runs have zero
uncaught page errors and zero harness errors. Negative failures are caught test
outcomes, not incomplete processes. Real iframe Documents, DOM, focus/inert state,
button.click(), and browser timers execute. Native endpoints, Core frame callbacks,
producer evidence, and the paginator interface are explicit controlled inputs.

The first nine focused cases failed on the original source. A first candidate
passed them and the inherited cases. The expanded review then exposed six more
failing cases involving stale projector lookup, scope fallback, and receipt
ownership. A later URL-preparation case failed before its repair. The final pass
added two failing frame-alias tests before separating the projection copies.
All these intermediate receipts are retained; none is relabelled as final success.

Eleven independently generated, syntax-checked partial reversions fail their
unchanged targeted runtime assertions: cleanup containment (5 failures), projector
checks (2), projection aliasing (2), immutable scope values (1), scope incarnation
(2), observed-frame cleanup (1), independent close (1), preparation capture (1),
location admission (3), invalidator lookup (1), and account observer ordering (5).
The test verifier requires the complete named roster and actual process statuses.

## Reproduction and integration

From the runnable packet, with installed Node, Python Playwright, and Chromium:

```sh
python run_checks.py --phase node --output /tmp/book-runtime-node-fresh
python run_checks.py --phase faults --output /tmp/book-runtime-faults-fresh
python run_checks.py --phase browser --output /tmp/book-runtime-browser-fresh
python run_checks.py --phase inherited --output /tmp/book-runtime-inherited-fresh
python test_apply.py
```

Each output directory must be new. The known original/fault controls intentionally
exit 1; the verifier succeeds only when those complete negative receipts match.
The package's guarded installer checks complete production preimages and new-path
collisions and never stages, commits or pushes. Patch hashes are in change.json.

The inspected `.github/workflows/book-actions-tests.yml` already includes
`Tests/JavaScript/*.test.mjs`, so the new Node file is selected without changing
CI. The new browser runner is an explicit component reproducer; no additional CI
browser step or current complete-workflow result is claimed.

Keep #116 draft. No Reader gitlink, generated project, qualification ledger,
protected branch, native writer, schema, protocol field, release action or Codex
task changed. Full Lake/Core JavaScript, actual Realm/CloudKit/WKWebView, full
Foliate, and assembled Reader/iOS acceptance remain separate. Historical native
passes do not qualify this modified source. The connected tools in this turn
expose repository reads but no commit/branch-write action; no new remote commit
or PR change is established.
