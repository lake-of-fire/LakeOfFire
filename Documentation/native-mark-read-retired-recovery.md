# Retiring obsolete completed-command recovery

## Failure

A native Mark or Unmark can finish after its originating page departs. The
coordinator settles the original command and removes it from the pending-command
map, but retains its separate read-only History recovery. Native command truth
and presentation recovery have different lifetimes.

The Reader's chapter/account invalidation calls `cancelAll`. Visiting only the
unfinished-command map misses completed recovery records, leaving their notice
and local query waiters alive after that presentation is obsolete. Same-chapter
movement can invalidate the recovery's location revision without another
projection-invalidation callback; merely stopping its next status post also
leaves the old recovery behind.

## Correction

The existing recovery ownership callback decides whether a captured recovery
still belongs to the current presentation. One private helper checks it, then
rechecks the exact map entry before retiring that record, its existing timer,
its local retirement/join promises and its notice.

Request admission, retained status observation and bulk cancellation share this
helper. Bulk cancellation captures both recovery and unfinished-command entry
rosters before invoking callbacks. A callback-created successor is never added
to the predecessor's cleanup sweep.

A same-owner recovery with temporarily absent chapter context remains valid.
An active failed recovery remains failed; no new sample is automatically issued.
Native success/failure/unavailable truth, the original command Promise, Undo
window and original transport identity remain unchanged. Completed commands
receive neither Cancel nor replay from this cleanup.

The newer initial-post local-failure path and shared control-packet builder are
preserved. This correction does not turn an unsent command into a recovery or
change the treatment of a native terminal received before a transport exception.

## Regression coverage

`native-mark-read-retired-recovery.test.mjs` imports the complete coordinator,
Book state controller and recovery adapter through ordinary production imports.
Native responses, lifecycle/timers, notices and the Reader's ownership callback
are controlled collaborators, not a full Viewer or WKWebView.

The cases cover chapter and account departure, same-chapter movement, failed and
held queries, independent successor progress, same-value return, callback-created
successors, original command truth, ordinary cancellation and preservation of a
still-current recovery whose context is empty.

```sh
node --test --test-concurrency=1 Tests/JavaScript/native-mark-read-retired-recovery.test.mjs
```

Native/browser acceptance must exercise departure and return with Unmark in
flight, then chapter/account replacement during status observation and an active
recovery query. A stored mutation must not be repeated and a new live chapter
must not wait for an obsolete query.
