# Advance after the committed page Mark is presented

The EPUB page Mark action records the visible page and advances after its read
animation. Its native command result and full chapter reading publication arrive
independently. `BookReadingStateController.refresh()` requests the publication;
it does not wait for native persistence, presentation construction, or WebKit
message delivery. A publication arriving more than 430 milliseconds after the
successful command previously missed the one-time advance check permanently.
The Mark remained saved, but the advertised page advance disappeared.

Reader now retains one optional continuation for that committed page Mark.
The existing 430-millisecond interval is a minimum animation duration. Once it
elapses, an accepted full native publication can resume the action. Publication
retries run after `onState` returns so navigation cannot interrupt that same
state acceptance. The native Mark result returns without waiting for the optional
publication or page turn.

Advancement still requires the original Reader, renderer, document, visible-page
generation, account, chapter pass, runtime event, Mark generation, and child
navigation receipt. The current successfully applied full publication must have
at least the command's snapshot sequence and contain every submitted stable
segment. Request-scoped success fields do not supply this evidence. Reader
consumes the exact continuation before calling the renderer, so later
publications cannot replay it.

A new page Mark or Mark All retires the continuation at admission. Close, reopen,
pagehide, visible-page invalidation, and unavailable chapter/account state retire
it as well. Explicit page-turn admission revokes the child navigation receipt
before asynchronous preparation or queuing; an earlier Mark reply cannot steal
that turn while native page metrics are pending. Trusted child navigation,
including the Unmark gesture, also invalidates the captured receipt. A read-only
status recovery does not create a continuation.

`ebook-viewer-page-tracking.test.mjs` evaluates the complete shipping Reader
class with the production book-state runtime and native request coordinator.
Focused cases hold the publication until after the animation, require exactly
one deferred turn, supersede the action before publication, and suspend explicit
native turn preparation while the old Mark reply arrives. Existing cases cover
animation-first/publication-first ordering, failed publication, account/pass
retirement, page lifetime, native failure, and outcome-only delivery.
