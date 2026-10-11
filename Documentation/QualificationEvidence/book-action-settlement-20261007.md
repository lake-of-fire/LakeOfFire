# Book Action settlement and preparation review - October 7, 2026

## Source and scope

This is a follow-up to Lake #115 at
`a4f9d54538c326132dba9ea4588128559537c257`, tree
`4200986317151baa78e5d3e3287e1b1b086edac3`. The complete controller repair from
that PR is retained. Reviewing its adjacent bridge and actual End of Book
consumer exposed separate result-lifetime defects.

Only `book-action-bridge.js` changes in production: 118 additions / 52 removals.
The four other paths add a Node suite, a browser case catalog/runner and this
report. No existing regression assertion or runtime module was replaced. The
32-entry completed cache, original semantic request/context/producer, account
stamp ordering, protocol version, 15-second deadline and native write contract
remain. Reader #286 remains the root integration owner; #112/#114 work is not
removed by this parallel follow-up.

## Reproduced defects

1. `settle` marked a delivery settled before calling a potentially throwing timer
   cleanup, but resolved/rejected its Promise only afterward. An accepted native
   result could therefore leave its original Promise and real End of Book button
   permanently busy. Timeout, closure and account withdrawal had the same gap.
2. The bridge removed a native delivery before copying its reply. Copy failure
   consumed a valid reply; copy-time reentry could supersede the delivery; and
   validation checked the original object rather than the serialized outcome.
   The result handed to the original consumer also aliased the recovery cache:
   changing `result.navigation.status` changed subsequent recovery behavior.
3. Context/producer/identifier preparation could synchronously reenter, allowing
   overlapping semantic commands or retaining an unsent old-account request.
   Timer installation or envelope construction could retire a delivery before
   it was posted, yet the old continuation still sent it or retained a late
   returned timer handle. A nested recovery during producer capture could post
   two status deliveries rather than share the already selected Promise.

These are executed controlled counterexamples, not attribution of a customer
Unmark incident to every boundary. Browser/native callbacks normally provide
plain data and working timers; exceptional callback behavior is injected where
specified. Returned-result mutation needs no failing timer or hostile accessor.

## Repair and refactoring

Timer retirement uses one helper that releases the captured handle and contains
optional cleanup failure. Terminal acceptance prepares validated defensive data
and per-delivery result copies before removing any request. It then updates the
private cache/current-delivery indexes before invoking timer cleanup or Promise
settlement. An account change or successor command in cleanup cannot repopulate
old state or change an already accepted result. Original timed-out commands may
still settle the active status observation truthfully; recovery never replays a
semantic mutation.

The cache and each distinct delivery receive separate result objects. Multiple
callers deliberately coalesced onto one Promise still share that Promise; this
is not a claim of separate values for every callback on a shared Promise.

Synchronous preparation uses a local reservation with a `finally` release and
checks its original account/document state. Rejected nested preparation has not
submitted a mutation and does not fabricate an unknown native outcome. Once a
delivery exists, host transport/timer errors retain the existing conservative
unknown-outcome/status-recovery policy. A timer failure does not create an
automatic retry or permission to issue a second reset.

The original request and exact active delivery are revalidated after timer and
producer callbacks. Late returned timer handles are disposed instead of attached
to an already settled delivery. Nested producer capture joins the selected live
status/navigation Promise or observes its cached outcome rather than overwriting
that delivery.

The second pass added a missing defensive-copy check: a truthy captured context
could serialize to null or an array. The first candidate failed those two added
cases. Final code rejects them before reserving a native command, releases the
preparation reservation and permits a valid deliberate retry. Full native context
schema validation remains native-owned; this is not a substitute schema.

No additional coordinator, native writer, schema, wire field, polling loop,
retry queue or timer lifetime is introduced. Ordered native state, not a command
reply, still determines the displayed Finished value.

## Actual verification

Node 22.16.0 and installed Chromium 144.0.7559.96 on Linux. The final Node selection
has **153 unique tests: 53 new and 100 unchanged**. The unchanged selection is the
79-case controller/runtime roster plus 21 existing bridge/recovery cases. All
seven test files are explicitly selected; no test is filtered or skipped. The
64-step state-history check counts as one test, not 64 tests.

| Exact final selection | Passed | Failed | Skipped / cancelled | Exit |
| --- | ---: | ---: | ---: | ---: |
| Node serial | 153 | 0 | 0 / 0 | 0 |
| Node JIT disabled | 153 | 0 | 0 / 0 | 0 |
| Node reversed order / concurrency four | 153 | 0 | 0 / 0 | 0 |
| New tests with original complete bridge | 7 | 46 | 0 / 0 | 1 |
| New real-DOM bridge/endcap browser scenarios | 18 | 0 | 0 / 0 | 0 |
| Same browser scenarios with original bridge | 3 | 15 | 0 / 0 | 1 |
| Unchanged complete runtime/endcap browser scenarios | 16 | 0 | 0 / 0 | 0 |

Both positive browser runs and the negative browser run have zero page-script or
harness exceptions; failures are retained scenario assertions/errors. New browser
fixtures use real setTimeout/clearTimeout, DOM controls and actual button.click().
Native replies and exceptional timer/producer callbacks are controlled. The
unchanged browser roster executes the complete controller, runtime, action bridge,
endcap, producer-evidence and renderer-selection modules with controlled native
and paginator interfaces.

Ten independent partial reversions pass syntax checking and fail behavioral tests:
cleanup exceptions (7 failures), result aliasing (3), final reply ownership (3),
validation of original instead of copied envelope (4), late timer disposal (4),
post-dispatch ownership (2), preparation reservation (4), copied-context shape (2),
recovery coalescing (1), and private-cache publication ordering (1). These overlap;
the failure counts must not be summed as distinct defects.

Earlier candidate results and the second-pass two-failure run are retained
separately. Final positive configurations reuse identical source/test hashes.
No predecessor or unrelated native result is promoted by this record.

## Exact inputs

| File | Git blob |
| --- | --- |
| Original bridge at the PR parent | `afa7b0818431d0315a741d575ca26be9500d4a12` |
| Revised complete bridge | `66223e038f7c4833ebec1534cdd17ea5b2998f6c` |
| New Node suite | `ade69eb376389ceb989361053d1c0ce41453cadf` |
| New browser cases | `efd274b0a1dea31345db759d2e4e2747dcff8a10` |
| New browser runner | `03d6a17af82c002d40c718c705b540a67e7dd973` |
| Unchanged existing bridge tests | `e70ef61d560b27799077d6fbdaf84c6353ad3398` |
| Unchanged existing recovery tests | `a154b4af9a8fb68397b489059731e1274f237ab6` |

The two additional inherited suites were fetched at the exact PR-parent ref and
matched to those original Git blobs. A fresh checkout could not be cloned from
this network-restricted runtime; the executed local tree is an explicit sparse
source/test selection, not a claim of a complete repository checkout. All owning
production modules used in these tests are complete files, not copied algorithms.

## Reproduction and integration boundary

From Lake with Node and installed Python Playwright/Chromium:

```sh
node --unhandled-rejections=strict --test --test-concurrency=1 \
  Tests/JavaScript/book-action-settlement.test.mjs \
  Tests/JavaScript/book-action-bridge.test.mjs \
  Tests/JavaScript/book-action-recovery.test.mjs \
  Tests/JavaScript/book-reading-state.test.mjs \
  Tests/JavaScript/book-reading-publication-revalidation.test.mjs \
  Tests/JavaScript/book-reading-runtime.test.mjs \
  Tests/JavaScript/book-state-publication-transaction.test.mjs
python3 Tests/Browser/BookActionSettlement/run.py --output /tmp/book-action-settlement.json
python3 Tests/Browser/BookStateTransaction/run.py --output /tmp/book-state-runtime.json
```

Use fresh browser output paths. New Node tests accept `LAKE_BOOK_ACTION_SOURCE`;
the browser accepts `--bridge-source`. Retained controls include the original
bridge and its unchanged local imports. The downloadable packet provides exact
inputs, completed process logs, a patch, and an independent selected-roster runner.

Keep Lake #115 draft and integrate its descendant without dropping #112/#114.
No Reader pin or qualification ledger changes here. This does not execute the
complete Lake/Core JavaScript workflow, actual Realm/CloudKit/WKWebView, full
Foliate paginator, Xcode discovery, or assembled iOS application. Historical
startup/first-Mark/saved-position and genuine distributed-account gates remain
separate. No protected merge, deployment, release or Codex task is authorized.
