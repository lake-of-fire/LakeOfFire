# Book Action wire identity and recovery selection — October 7, 2026

## Final source boundary

This is a follow-up for LakeOfFire #115, branch
`fix/book-state-publication-transaction-20261007`, inspected at
`045484964c15bef33569cf0888a2344dce8727e1`. It is **not published** by this
continuation: the available GitHub actions expose reads, not commit/ref writes.
No Reader pin, existing PR metadata, protected branch, or qualification flag changed.

The initial source was #115's `a4f9d545`. During review, `04548496` independently
landed substantial repairs to the same bridge. Its complete bridge was fetched,
matched to Git blob `66223e038f7c4833ebec1534cdd17ea5b2998f6c`, and retained as the
new preimage. This patch does not replace that implementation with the earlier
local candidate. The net production change is **33 added / 7 removed lines in
one file**, `book-action-bridge.js`. Five additive paths supply the new Node
suite, browser fixture/cases/runner, and this report.

Final production blob: `7212828eef89e2262c4c55c13ec86b0f883fd230`.
The concurrently published 53-case settlement suite is unchanged, blob
`ade69eb376389ceb989361053d1c0ce41453cadf`, and runs in the final selection.

## Remaining defects reproduced on that concurrent source

### Wire preparation could change the reserved operation

The bridge reserves an immutable semantic request but handed the producer adapter's
returned object directly to native `postMessage`. An adapter or serializer could
change its action, request/delivery ID, context, protocol version, or other original
wire fields. The eventual result was still correlated with the bridge's original
request. The new tests demonstrate rejected changes to each relevant field before
and during serialization; the real endcap browser cases demonstrate a clicked
Finish being retargeted to Start Book Over, or to another context, at the controlled
producer boundary. These are executed counterexamples, not claimed customer events
or actual native writes.

Prepare a plain JSON envelope after the producer adapter, compare its original
semantic fields with the reserved request, and recheck the existing delivery owner
before dispatch. Object-key order is irrelevant; no native schema or new wire field
is introduced. The adapter may continue adding producer evidence.

A second review of the local candidate caught an important compatibility defect:
the actual `carryReaderArticleProducerOwner` fallback attaches evidence *in place*.
Reading semantic keys after that callback incorrectly rejected legitimate evidence.
The final code captures the key set beforehand. The actual compatibility helper and
a real-browser in-place producer adapter both pass without changing their behavior.

### Recovery could select a request created by descriptor accessors

`recover()` read the descriptor before selecting `current` or the completed cache.
An accessor could change accounts or admit and complete another request, then return
that request's ID. The old invocation thereby acquired the new request's outcome.
Throwing descriptor accessors also escaped synchronously instead of returning a
rejected Promise.

Select from the original current request and a synchronous snapshot of the existing
32-entry cache, retaining the account across descriptor access. Actual membership
is checked again before use. No persistent registry, lock, generation or timer is
added. This preserves the existing coalescing of a nested active status delivery;
it does not replace that Promise with another attempt.

### Cached ID reuse and repeated error getters

A faulty/injected identifier provider could reuse an ID still in the completed
cache for a different semantic action. That is now rejected at preparation without
posting another command. This is a bounded-cache guard, not a claim of permanent
UUID uniqueness after eviction. The existing 32-entry capacity remains unchanged.

Optional error formatting sampled `error.message` up to three times. It now reads
that value once, so a getter cannot reenter the bridge repeatedly merely because
an error is being described. Native success accepted by that getter remains success.

## Concurrent policies deliberately preserved

The concurrent source's synchronous preparation reservation remains authoritative:
a nested activation rejects, while the original activation retains admission.
An unavailable timeout facility returns an unknown/recoverable Promise and posts
no mutation; subsequent recovery remains status-only. A nested status attempt
created by producer capture remains coalesced. These differ from choices in the
superseded local candidate; its unpublished tests were reconciled to the already
landed contract, while the exact upstream assertions were retained unchanged.

The incoming defensive result-copying, reply correlation, cache/consumer isolation,
timer-handle disposal, account retirement, and terminal bookkeeping repairs are
preserved. No second settlement implementation, replacement timer policy, epoch
writer, automatic retry, polling loop, or duplicate native command was added.

## Final executed checks

Linux Node 22.16.0; Chromium 144.0.7559.96. All Node fixtures execute the complete
production bridge and real Promises. The final roster contains **220 unique tests**:
67 in the new suite and 153 unchanged inherited tests, including all 53 cases from
the concurrent settlement commit. Repeated configurations do not increase that count.

| Run | Passed | Failed | Skipped / cancelled |
| --- | ---: | ---: | ---: |
| Final source, serial | 220 | 0 | 0 / 0 |
| Final source, JIT disabled | 220 | 0 | 0 / 0 |
| Final source, reversed order / concurrency four | 220 | 0 | 0 / 0 |
| Same 67 new cases, unchanged `04548496` bridge | 47 | 20 | 0 / 0 |
| Final source, new browser scenarios | 17 | 0 | 0 / 0 |
| Same browser cases, unchanged `04548496` bridge | 15 | 2 | 0 / 0 |
| Final source, inherited controller/runtime browser cases | 16 | 0 | 0 / 0 |

Both final browser comparisons have zero page-script errors and zero harness errors.
The complete runtime, controller, endcap, action bridge, producer-evidence and
renderer-selection modules execute. Native endpoints, Core frame projection and
paginator interfaces are controlled. Buttons, iframe Documents, Promise delivery
and host timers are actual Chromium behavior. The 15-second timeout is shortened
to 80 milliseconds by the fixture; exceptional timer/adapter callbacks are explicit
injections. This is not genuine native mutation, WKWebView or the full paginator.

Six independently generated faulty variants compile and fail the unchanged final
new suite: removing wire comparison (12 failures), omitting the post-serialization
owner check (1), permitting cached ID reuse (1), selecting a newly created recovery
request (1), resampling the error getter (1), and sampling semantic keys after
in-place evidence attachment (1). No source-text assertion substitutes for behavior.

## Evidence and reproduction

The packet retains final process exit codes, TAP/stdout/stderr, browser JSON,
input hashes and exact current original source. Its verifier uses explicit test
paths and checks complete rosters rather than treating a filtered run as a pass.
The patch and guarded installer do not stage, commit, push, regenerate, or touch
unrelated files. The installer requires the intended branch and exact preimage.

From a complete checkout:

```sh
node --unhandled-rejections=strict --test Tests/JavaScript/book-action-bridge-settlement.test.mjs
node --unhandled-rejections=strict --jitless --test Tests/JavaScript/book-action-bridge-settlement.test.mjs
python3 Tests/Browser/BookActionIntegrity/run.py --output /tmp/fresh-book-action-integrity.json
```

The supplied standalone packet additionally runs the eight-file 220-case selection
and the inherited 16-case browser runner. Browser output paths must be fresh.

Earlier receipts remain under history/evidence: the first local timer/settlement
candidate, its recovery-selection and wire refinements, and the comparison before
concurrent-source reconciliation. One early test awaited navigation when it intended
a cached status read and was cancelled; another fixture failed to request its second
Finished publication. Both were corrected before final evidence. The in-place
producer test first failed the local candidate, then passed the final key capture.
Those intermediate passes/failures are not transferred to the final composition.

## Unexecuted integration

A direct public clone failed because the container could not resolve github.com.
The selected complete sources were instead obtained from the connector and the
verified retained packet. This is not a complete Lake checkout or a complete
Lake/Core JavaScript workflow. Real Realm/CloudKit, native Book Action execution,
Apple/WKWebView, full Foliate, current Reader dependency composition and assembled
iOS journeys remain unexecuted here. Keep #115 draft. Reader #286 must integrate a
reviewed descendant preserving its selected #112/#114 work; this task repins nothing.
