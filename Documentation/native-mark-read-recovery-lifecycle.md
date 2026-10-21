# Mark/Unmark outcome recovery and snapshot ordering

The command coordinator and Book state controller have separate responsibilities.
The coordinator retains an admitted mutation's outcome and native recovery proof.
The Book controller owns the ordered, full reading projection. Neither a timeout
nor a partial command reply is permission to repeat a mutation or navigate.

## First submission is different from restored observation

Before initial transport entry, lifecycle registration, timer setup and the
original owner predicate can retire the request. Recheck that exact pending
entry, visibility, cancellation and owner after these callouts. A never-submitted
request completes locally with a known negative outcome. It must not create a
History recovery record or use the restored status path to send its first
mutation.

The initial transport callback retains its existing no-handoff exception contract.
If it throws after departure, or diagnostic formatting itself causes departure,
settle the still-owned request as a local known failure. Otherwise its departed
flag creates a History barrier for an unsent command: resume polls it, native
cannot acknowledge it, and a deliberate retry is blocked. Both rejected first
admission and failed first posting use `finishLocalFailure`; clear only this
request's recovery-only disposition before its terminal settlement.

The exact pending-entry check matters: a native terminal received synchronously
has already consumed that entry and wins over a later wrapper exception. Its
real recovery remains intact. Preserve `recoveryRequested`, because a different
joined recovery may be waiting for this ordinary request to drain.

This does not broaden the transport contract: after a successful handoff, status
failures and local disposal cannot prove the submitted mutation failed. Controlled
callback schedules demonstrate the coordinator bug, not customer incidence or a
native storage failure.

## Keep terminal truth across departure and native retention loss

An ordinary terminal may arrive after departure removed the request's ability
to paint. Its original waiter still receives the known native result, while a
separate recovery record waits for current presentation. The existing lifecycle
and status observation must retain that record until native admits its read-only
sample; observing only still-pending mutations loses the return handoff.

Pause cancels the exact observation timer. Return restarts status observation
using the same request ID and token. Native admission stops that polling phase
before the single sample starts. Refused preparation or a failed sample settles
presentation failure without an automatic new sample.

A canonical `unavailable` reply can acknowledge an exact retained recovery proof
after native expires its bounded outcome entry. It must not overwrite a known
JavaScript result or settle the original promise again. An originally unknown
outcome stays unknown. Extra success fields, foreign tokens and contradictory
known outcomes do not grant recovery admission.

## One semantic snapshot and one control envelope

Capture caller getters and JSON serializers once before coalescing and admission.
The canonical fingerprint and transmitted command must use that same plain
semantic object; otherwise a changing desired-state getter or Book-scope
serializer can describe different operations. Append the coordinator-owned request
ID, section, protocol and observation token after this capture, then freeze the
packet. Caller serialization cannot replace its correlation capability.

Status, Cancel, retained-outcome observation and Close all build control messages
through `nativeMarkReadControlMessage`. It reads the original frozen command's
identity, never current page metadata or an earlier transport's edited packet.
The caller still decides whether its operation is admitted; the helper neither
checks authority nor dispatches work.

Transport diagnostics are best-effort. A throwing `message` getter or string
conversion cannot interrupt local settlement or observation of a submitted
command. Diagnostic failure is not a replacement native outcome.

## Cancellation is a bounded operation

Cancel All captures its entry roster before invoking callbacks. A callback can
settle an original command and create another request, even for the same section.
That successor is not part of the old cancellation operation. Each captured
request still revalidates its own live owner before cancellation.

## Partial receipts cannot overrule a newer full projection

A full native reading snapshot can arrive before its command's partial reply.
Reuse that already accepted, newer full snapshot without lowering its sequence
or replacing an unrelated pending query. Rendering and subject-coverage checks
still decide whether an optional page advance may proceed.

Conversely, a later partial Unmark can advance native ordering while an older
full projection remains cached. The page-advance coverage predicate must check
that ordering as well as rendered sequence and membership. Old marked coverage
is not authority to advance after a newer receipt has overtaken it.

## Runtime regression coverage

`Tests/JavaScript/native-mark-read-recovery-lifecycle.test.mjs` imports the complete
production coordinator, Book controller, producer helper and UUID module. It
combines hidden Mark/Unmark success and failure, explicit recovery admission,
native retention expiry, refused/throwing preparation, account retirement,
callback-created cancellation successors and full/partial snapshot arrival order.
Native packets and timer/lifecycle callbacks are controlled collaborators.

`Tests/JavaScript/native-mark-read-control-composition.test.mjs` additionally
combines captured intent with status/Cancel/Close envelopes, diagnostic failures,
known native results preceding wrapper errors, departure during failed initial
posting, and release of a separate recovery waiting for an ordinary request.
The tests use public coordinator seams and state outcomes, not source-text checks.

Run the focused component suites with:

```sh
node --test --test-concurrency=1 \
  Tests/JavaScript/native-mark-read-recovery-lifecycle.test.mjs \
  Tests/JavaScript/native-mark-read-control-composition.test.mjs
```

This is component integration, not browser/BFCache, real native retention,
WebKit, persistence or complete renderer qualification. No mutation replay,
new status protocol, native retention policy, timer cadence or persistence
schema is introduced.
