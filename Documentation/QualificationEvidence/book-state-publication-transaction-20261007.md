# Book-state publication and read-request ownership — October 7, 2026

## Source scope

A fresh review first reran the published Core passive-history repair against
Core #451 at `5eff7a6663db4be79a4f4fc295d774b34981b42e`. Its exact current transport
blob `b032e097f03825702c04e03077eea23a3b6c1d8c` passes the unchanged 98-case Node
and 98-case Chromium passive-status suites. No further Core production change
is proposed in this increment. These selected results are not a new complete
Core JavaScript or native application qualification.

The review then followed Book state into Lake's actual controller, runtime,
endcap, action bridge, producer evidence helper and renderer selection helper.
The original controller is blob `8a12f22682e7a70b6ebc1d60deab2949db655645`, identical
on selected Lake #112 `fca4e8b570a978918b4d31770d4bf36de8735e68` and `v3-hotfix`
`e5157aab215286a34a2b4b970ef5c37012401405`. The five commits between those refs
change only inventory-manager source, tests and documentation. This focused
follow-up targets v3-hotfix without copying or replacing that unrelated work.

## Reproduced defects

The controller consumed the pending native read and advanced its snapshot
watermark before completing both defensive copies. A serialization failure
could strand the original reply and leave state/context inconsistent. Copy-time
callbacks could also accept a newer publication, close or relocate the reader,
or replace the account before the older copy resumed and overwrote it. Validating
the original object did not validate a different model returned by `toJSON`.

A read bridge that threw after synchronously publishing a valid reply cleared
the accepted context and disabled the real End of Book button. An older failed
post could likewise clear a nested replacement request. Comparing only wire-ID
values cannot identify which local invocation owns that cleanup when an injected
request-ID provider repeats a value.

Account-change callbacks could already publish a fresh same-account sample.
The older account transition subsequently called the actual runtime invalidator,
which retired the new scope/event receipts even though current state remained
available. A callback that only queued a fresh request instead caused a redundant
second request from the outer runtime method. Relocation had a corresponding
nested-request replacement path.

These are controlled behavioral counterexamples, not claims of observed user
incidents. Native responses are normally plain serialized data; deliberate
serializers/getters and synchronous bridge callbacks expose the transactional
and callback boundaries. Browser checks also execute actual DOM control and
runtime receipt behavior rather than calling a disabled control's handler by hand.

## Repair and bounded refactor

Prepare state and context together, validate the copied model, and prepare the
renderer-facing copy before consuming the pending request or changing the
watermark. Recheck the original private state/account/location/request identities
at the final commit boundary. All accepted fields change without an intervening
external callback. The renderer still receives independent data and the original
publication-current predicate.

Centralize existing identity checks into two private receipts. A pending read
and an accepted projection intentionally have different lifetimes: queuing a
background read does not withdraw an accepted display, while a newer publication,
account, location or manual snapshot does invalidate an older acknowledgement.
Public callback resolution is checked before invocation, not just before lookup.

The one pending slot now stores `{ requestID }` instead of only the string. This
is a local cleanup identity, not a new wire token or native admission authority.
Failed posting withdraws only that exact unconsumed request. It invalidates
readiness only while its original projection is still current; it cannot undo a
synchronous accepted reply or erase a nested request. Ordinary posting failure
still invalidates readiness once, and explicit refresh remains possible.

Account and relocation effects stop when their callbacks already selected a
successor. A merely queued account sample still clears old frame scopes, but
its request is retained and the outer method does not enqueue another. Closed
controllers reject late manual snapshot acknowledgements.

No native writer, epoch mutation, schema, persisted field, sidecar reconstruction,
new timer, queue, retry loop or full ownership framework is introduced. Native
correlation, producer validation and the existing action bridge remain unchanged.
One production JavaScript file changes. Existing regression files are unchanged.

## Executed verification

Linux Node 22.16.0 and installed Chromium 144.0.7559.96.

| Exact final selection | Passed | Failed | Skipped / cancelled |
| --- | ---: | ---: | ---: |
| Four Node files, serial | 79 | 0 | 0 / 0 |
| Same files, JIT disabled | 79 | 0 | 0 / 0 |
| Same files, reversed order / concurrency four | 79 | 0 | 0 / 0 |
| New Node suite against complete original controller | 4 | 28 | 0 / 0 |
| Chromium, complete runtime composition | 16 | 0 | 0 / 0 |
| Identical Chromium scenarios, original controller | 3 | 13 | 0 / 0 |

The Node roster contains 32 new cases plus 47 unchanged cases: the original
state, publication-revalidation and runtime suites. Configurations do not count
as additional unique tests. Every final positive process exits 0. Both browser
comparisons have zero page-script errors and zero harness errors; negative
results are recorded scenario failures, not missing modules or broken setup.

Seven independent source variants compile and fail the same new 32-case suite:
consume the request/watermark before copying (23 failures); validate original
rather than copied data (2); drop pending-request admission checks (5); let a
queued request withdraw accepted display (3); ignore the manual watermark (3);
clean up a nested request by equal ID rather than identity (1); and retain a
withdrawn request slot (1). No runtime assertion depends on source-string shape.
The source transformations are fault preparation, not verification assertions.

The second review pass found a defect in the first candidate itself: a failed
read whose callback advanced the manual watermark could keep a phantom pending
slot. Two added Node cases failed that candidate. The final cleanup separates
logical request withdrawal from optional display invalidation. Both now pass,
as do the corresponding real-endcap browser cases. Earlier red and intermediate
receipts are retained rather than relabeled as final evidence.

## Browser and platform boundary

The browser imports the complete unmodified runtime, endcap, action bridge,
producer-evidence and renderer-selection modules alongside the chosen complete
controller. Only relative static import specifiers are redirected to offline
data URLs. The fixture makes no network requests or browser downloads.

Real DOM, a real iframe Document, End of Book disabled-button clicks, Promise
microtasks, action-bridge timers and runtime scope/event receipts execute.
Native message endpoints, the Core frame projector, producer ticket and paginator
interface are explicit controlled collaborators. This does not execute native
Realm/CloudKit writes, WKWebView, the full Foliate paginator or assembled Reader.
A successful action acknowledgement does not select Finished; that remains an
ordered native-state publication decision and has a passing browser control.

## Reproduction

From a complete Lake checkout:

```sh
node --unhandled-rejections=strict --test --test-concurrency=1 \
  Tests/JavaScript/book-reading-state.test.mjs \
  Tests/JavaScript/book-reading-publication-revalidation.test.mjs \
  Tests/JavaScript/book-reading-runtime.test.mjs \
  Tests/JavaScript/book-state-publication-transaction.test.mjs
python3 Tests/Browser/BookStateTransaction/run.py --output /tmp/book-state-current.json
```

Use a fresh browser output path; earlier evidence is not overwritten.
`LAKE_BOOK_STATE_SOURCE` selects an exact alternative source for the new Node
suite; `--state-source` does the same for the browser. Original comparison and
fault-variant files, selected immutable dependencies, per-process receipts and
hashes are retained in the conversation evidence packet.

## Integration and remaining acceptance

Keep the focused Lake follow-up draft. Reader #286 must reconcile a descendant
Lake pin with its other selected changes; this increment does not repin Reader,
alter native test inventories or move a qualification flag. Core #451's earlier
complete-JavaScript results do not qualify changed Lake source. Complete current
Lake/Core JavaScript workflows, Apple/WKWebView/Realm integration, historical
startup/first-Mark/saved-position journeys, genuine distributed-account evidence
and assembled application acceptance remain separate. No protected merge,
production mutation, release or deployment is authorized by these component tests.
