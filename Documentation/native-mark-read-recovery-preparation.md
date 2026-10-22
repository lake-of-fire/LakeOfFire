# Failed Unmark status preparation must not remain visibly pending

## Failure sequence

A departed Mark/Unmark can first receive its terminal native outcome and then
recover the current chapter's reading status. These are separate operations:
the saved/rejected/unknown mutation outcome is already settled before the
read-only display recovery begins.

The coordinator prepares the recovery when the terminal arrives and prepares
it again when native authorizes its queued query. If the first preparation
succeeds but the authorized preparation returns false or throws, the previous
implementation returned false before publishing the recovery's failure notice.
The UI could remain on "Refreshing reading status" with no read outstanding.
A queued sibling's first failed preparation could leave the same stale notice.

The native final-failure notification does not repair this case: its separate
admission requires a ready recovery. This defect is presentation settlement,
not a failed or reversed Unmark write.

## Settlement rule

Keep retirement as an early exit, but route preparation refusal through the
same exact-owner settlement used by a failed status query. Invoke the query
only when preparation succeeded. A live owner receives `recovery-failed`; a
retired display receives normal notice cleanup. Duplicate authorization still
observes the original completion rather than starting another query.

The existing failed-recovery barrier stays installed. Do not allow another
Mark/Unmark against unrefreshed display state, replay the mutation, send Cancel,
renew Undo, add a timer, or retry automatically. Preserve the native outcome
independently of the display failure. The existing notice tells the user to
close and reopen the book when its current reading status cannot be recovered.

## Behavioral coverage

Run the focused preparation and existing queue suites:

```sh
node --test Tests/JavaScript/native-mark-read-recovery-preparation.test.mjs \
  Tests/JavaScript/native-mark-read-recovery-queue.test.mjs
```

The new suite imports the complete production coordinator and its real module
dependencies. It covers refused/throwing preparation, saved/rejected/unknown
native outcomes, duplicate authorization, concurrent recoveries, retirement,
failed optional notice callbacks and successful/failed query controls. One
case composes the actual Book state controller, recovery adapter and notice
formatter with explicit native-message and minimal DOM collaborators.

These controlled component tests do not establish real browser lifecycle,
WKWebView, Realm, device or full Reader qualification. Before release, exercise
a saved Unmark followed by a rejected chapter-status preparation and verify
that the failure instruction replaces the pending message without any second
mutation or loss of the original outcome.
