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

## Focused execution

Node 22.16.0. The new `book-navigation-recovery-intent.test.mjs` imports complete
production bridge, Book-state, Mark coordinator and actual producer/UUID
module dependencies. Native messages, frame receipt/Reader observer, timer
callbacks and lifecycle input are explicit controlled collaborators.

| Identical final fourteen tests | Passed | Failed | Skipped/cancelled |
| --- | ---: | ---: | ---: |
| Exact #234 bridge | 8 | 6 | 0 |
| Corrected bridge | 14 | 0 | 0 |

The six failures are variants of one missing navigation-intent admission, not
six independent defects. Tests cover chapter/whole-book retry, successful Mark
and full coverage, cached status, stale location and Article/chapter pass,
missing projection/producer, duplicate recovery, observer reentry, callback
account/location replacement, ordinary fresh command and stale-menu controls.
Negative controls release outstanding deliveries before failing their decisive
assertions; failures are not test-runner timeouts or missing dependencies.

The final focused selection, using the exact #234 Book-state source, passes
**45/45**, with zero failures, skips or cancellations: fourteen new cases,
nineteen unchanged cancellation/recovery-composition cases, and twelve unchanged
visible-Mark commit cases. Fourteen is included in forty-five. An earlier
8-case development checkpoint is not an additional test count.

```sh
node --test --test-concurrency=1 \
  Tests/JavaScript/book-navigation-recovery-intent.test.mjs \
  Tests/JavaScript/native-mark-read-cancel-recovery-integration.test.mjs \
  Tests/JavaScript/ebook-visible-mark-read-commit.test.mjs
```

Changed production/test JavaScript syntax and diff-whitespace checks pass.
This is not full Viewer execution, real renderer movement, native menu/transport,
BFCache, Realm, Swift/XCTest, Safari/WKWebView or device qualification. Native
acceptance should hold Go to Beginning after a committed failed navigation,
complete a separately admitted page Mark, and verify that only the explicit
recovery may move while the Mark remains successfully saved.

## Source and integration

Base: Lake #234, `integration/hotfix-unmark-prs-20261021`,
`e1ad62c7eff6a136fd12b32cc4eb05bb66608a4d`.
Original bridge: `74eb5b47c7a7cf2da10f3b8dfef40f61a482f8ee`.
Unchanged Book state: `b814b9818d2ca026ed8b0e5cd82589d6c68de0cf`.
Unchanged Mark coordinator: `dfcccb13e68e68360916e6287937b2684014786b`.
Runtime: `b054c3c7aaa0a7bb05aca92e71111e8803bd38c2`.
Viewer: `cf95be5063d491a7199af2fbdf31886d2e5fa7f6`.
Core menu inspected at `1cf0dc99f8d9b3b38a30f5877f6727bab3d73f48`;
menu blob `ead0a6c119bd13c4373f502b6b403675982736b0`.

The complete original bridge was checked against its Git blob before editing.
Publish only the bridge, new test file and this note. No existing integration
head or app gitlink is moved. Keep draft pending native qualification. Commits
use `[skip ci]`; no hosted workflow dispatch, shipping merge, schema, production
data operation or release action is part of this fix.
