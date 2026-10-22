# Go to Beginning retires older optional page-Mark navigation

## Supported caller and failure schedule

Core's `ReaderBookActionsObservedMenu.submit` invokes
`bridge.recover(recovery)` for the native recovery action. The invocation is a
trusted native action, but does not emit a navigation gesture in the chapter
Document. The Book runtime connects `onCommandAdmission` to the existing
`Reader.observeNativeNavigationIntent` observer. Before this correction only a
fresh `bridge.perform` invoked that observer; `recover` did not.

A supported interleaving is:

1. Start Chapter Over or Start Book Over commits and publishes its successor
   pass, but physical navigation fails. The bridge retains the original committed
   result and offers Go to Beginning rather than another reset.
2. The reader marks the currently visible page. Ready chapter controls permit
   that separate action. Its optional automatic turn retains the chapter's
   navigation receipt while awaiting native completion, full state or animation.
3. The reader explicitly chooses Go to Beginning. The retry posts a nonmutating
   `navigate` delivery for the original Book action without retiring the older
   page-Mark navigation receipt.
4. A late Mark publication can therefore remain eligible for automatic movement
   while the selected native navigation retry is pending. Movement can supersede
   the retry's original location admission.

The executed reproduction demonstrates the still-current receipt at native
retry handoff, not physical page movement on a device. It composes the complete
production bridge, Book-state controller, Mark request coordinator and final
coverage/navigation predicates with controlled native and frame collaborators.
The Reader/menu connections above were source-traced. No lost native support,
replayed reset, customer incidence or actual device navigation is claimed.

## Narrow correction

After a navigation retry has prepared its producer and immutable wire payload,
observe its explicit navigation intent through the existing callback. Match the
currently published successor to the known committed result and original
location first. Comparing the predecessor context ID would wrongly reject the
normal reset-to-successor transition.

The original article, resulting Article epoch, location revision and end-page
state must match. A chapter retry also requires the original section/chapter key
and resulting chapter epoch. A stale-location or newer-pass retry may still ask
native for its authoritative disposition, but cannot retire a newer local Mark's
navigation. Missing local projection preserves the existing native publication
recovery route; it does not invent local movement permission.

Capture and revalidate the complete selected context around the observer. The
existing active delivery is installed before the callback, so a nested recovery
joins that delivery instead of posting another. An observer that changes account
or location cannot post the old retry. A refused optional delivery retains the
original operation's status-recovery semantics; it does not report a second
reset or a failed durable write.

Status-only recovery does not express movement and never calls the observer.
The correction preserves Mark success/full display, native mutation fences,
commit-before-navigation, original reset identity, timeout/unknown-outcome
behavior and all existing cancellation/recovery composition. It adds no timer,
queue, protocol field, native mutation permission, storage or Undo-clock change.

Production delta: thirty added lines in the existing bridge. The runtime and
Viewer observer are reused unchanged. This is independent of #235's Book-state
History retirement fix and does not include the withdrawn complete-subject
coverage proposal.

## Verification

`Tests/JavaScript/book-navigation-recovery-intent.test.mjs` composes the production
bridge, Book state and Mark coordinator with controlled native/frame collaborators.
It covers chapter and whole-book retries, stale pass/location, nested recovery,
account changes and successful Mark coverage. Run it with the cancellation/recovery
and visible-Mark suites. Keep actual native menu, Viewer, Realm and device acceptance
explicit: a late successful Mark must stay saved while its old automatic movement is
retired by the user's Go to Beginning selection.
