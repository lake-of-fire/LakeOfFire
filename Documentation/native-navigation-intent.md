# Native Book Actions and progress scrub supersede optional page-Mark movement

The page-Mark continuation in #213 preserves its original chapter navigation
receipt while it waits for native full reading-state publication. Explicit native
page turns already retire that receipt before their asynchronous preparation.
Two other supported native entrypoints lacked the equivalent admission step.

The native Book Actions menu calls `bridge.perform(action, context)` without
dispatching a DOM event in the chapter. A selected reset can then wait on native
mutation work while an older committed page Mark receives its full publication
and advances. That relocation can invalidate the selected reset's native location
admission before commit. Beginning the native progress slider similarly opens a
scrub session without navigating. The first fraction navigation is debounced and
can be omitted entirely for no effective movement, leaving old Mark movement able
to overtake the user's slider grab.

`Reader.observeNativeNavigationIntent` retires the exact pending continuation and
calls the current chapter's existing `manabiObserveAutomaticScrollNavigation`
entrypoint. This also revokes the receipt of a Mark still awaiting native reply.
There is no new navigation clock, mutation cancellation, transport field or retry.
The durable Mark result and ordinary committed reading-state paint remain intact.

Book action admission invokes this observer only after validating and copying the
original context, producer and request identifier. It validates the same current
context immediately before and after the observer. A stale menu never reaches
the observer; account, location or lifecycle replacement during the observer
cannot post the old action or leave an unsent status-recovery reservation.
Existing command/status transport and recovery retain their separate semantics.

Scrub begin invokes the observer before opening a new scrub session, including
when the thumb has not moved. An already active session's duplicate begin does
not become another navigation intent. Reader/frame lookup and optional timer
cleanup reentry are checked against the original Reader, lifetime, renderer,
document, account, Mark generation and exact pending continuation.

The shipping Core provider installs the observer before its capture function and
retains/restores both closures together on reinjection. Failed navigation-listener
installation and pagehide invalidate existing receipts. There is no supported
provider transition that leaves an admitted current receipt while removing only
the observer. Hosts without that provider cannot capture automatic-advance
permission in the first place; this change does not add another fallback clock.

## Focused qualification

The maintained `ebook-viewer-page-tracking.test.mjs` harness evaluates the shipping
Reader class and actual native scrub startup entrypoint. It imports the complete
Book runtime, bridge and `captureVisibleMarkReadNavigation`. Its existing controlled
frame receipt provider and native transport collaborators expose the original
receipt and held publication; no navigation implementation is copied into a test.

The added cases cover all three accepted Book Actions before native reply, a
rejected stale menu, reentrant account replacement from the admission observer,
and a native slider grab without movement. They require committed Mark success
and paint to survive while optional movement is withdrawn. The stale menu control
requires the original Mark to continue advancing normally. Duplicate scrub begin
must preserve a receipt captured after the original begin.

The focused JavaScript suite exercises these transitions with controlled native
transport and frame collaborators. Its result does not establish native
WKWebView/menu/slider execution or full browser behavior; those checks remain
unrun. Keep composition qualification separate from each narrow regression.

```sh
node --test Tests/JavaScript/ebook-viewer-page-tracking.test.mjs
```

The production baseline is #213 `2d65e20df185abba87aa4f40c1338ef3359cde1d`.
#216 changes the separate delivery preparation-failure path in the bridge; #218
changes initial Mark/Unmark coordinator dispatch. Neither provides these native
intent admissions. Compose their respective changes without replacing these
admission checks.
