# Book action preparation and uncertain delivery

A new Book action must not enter status-only recovery until its initial native
transport invocation has been entered. Local envelope or timer preparation can
fail before that point. Native has no record of such a request, so Check Status
cannot resolve it; retaining the bridge's current request also rejects every
subsequent deliberate Finish or Start Over action.

The producer adapter can return null when Core rejects its original owner.
Serialization, semantic-envelope validation and timer installation are other
pre-dispatch failure boundaries. These are local admission failures, not native
mutation failures and not evidence that a submitted operation rolled back.

## Settlement rule

The bridge records entry into the existing postMessage callback immediately
before invoking it. A preparation exception for the fresh command removes only
that delivery and its exact current request before settling its promise or
clearing its timer. The caller receives an ordinary local error and may initiate
a new deliberate action after readiness returns. No automatic mutation retry is
introduced, and no old command is relabeled with a new producer.

After entering postMessage, an exception remains an unknown native outcome:
the transport may have delivered before throwing. Its original request remains
recoverable, and a second mutation stays prohibited until native answers.
Synchronous terminal acknowledgement still wins over a later wrapper error.

Status and navigation recovery are also excluded from local-abort cleanup, even
when their own preparation fails before posting: their original semantic command
was already submitted and may have committed. Preserve its immutable request ID
and use the existing status-only recovery path.

Timer expiry uses this same failure handler rather than a separate unconditional
unknown-outcome path. The injectable scheduler can expire while installing the
timer or preparing the envelope. Such an unsent fresh command releases its local
reservation; expiry after submission, or during status/navigation recovery,
still preserves the original operation. A late timer cannot retire a successor.
The early-expiry cases exercise the scheduler contract with controlled callbacks;
they do not claim that the browser's normal setTimeout runs synchronously.

## Regression coverage

Run:

```sh
node --test Tests/JavaScript/book-action-pre-dispatch.test.mjs \
  Tests/JavaScript/book-action-bridge-settlement.test.mjs \
  Tests/JavaScript/book-action-recovery.test.mjs
```

These suites import the complete shipping bridge and its real dependencies.
They exercise producer-envelope rejection, adapter exceptions, serialization and
semantic validation failures, timer setup/early expiry, local cleanup reentry,
ambiguous transport failure, timeout, synchronous terminal acknowledgement, and
failed status/navigation preparation. The existing settlement suite's throwing-
timer test now requires local rejection and a deliberate new command, not an
impossible status query for an operation never sent. Native transport and
scheduling callbacks are controlled collaborators, not native Realm or WKWebView.

Before release, exercise the actual End of Book and native Book Actions callers
with producer replacement, then verify that a genuinely submitted reset with a
lost reply still requires status recovery rather than a second reset.
